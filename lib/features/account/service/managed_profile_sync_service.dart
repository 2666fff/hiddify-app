import 'package:fpdart/fpdart.dart';
import 'package:hiddify/features/account/data/account_api.dart';
import 'package:hiddify/features/account/model/account_session.dart';
import 'package:hiddify/features/account/service/managed_profiles_writer.dart';
import 'package:hiddify/core/logger/huijia_debug_log.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

final managedProfileSyncServiceProvider = Provider<ManagedProfileSyncService>((ref) {
  return ManagedProfileSyncService(api: ref.watch(accountApiProvider), ref: ref);
});

class ManagedProfileSyncService {
  ManagedProfileSyncService({required AccountApi api, required Ref ref}) : _api = api, _ref = ref;

  final AccountApi _api;
  final Ref _ref;

  Future<Unit> sync(AccountSession session) async {
    await HuijiaDebugLog.info('managed profile sync start', {'username': session.username});
    final profiles = await _api.fetchProfiles(session);
    final repository = await _ref.read(profileRepositoryProvider.future);
    final writer = ManagedProfilesWriter(repository);
    for (final profile in profiles) {
      await HuijiaDebugLog.info('managed profile sync item', {
        'name': profile.name,
        'url': profile.url.replaceFirst(RegExp(r'(/sub/).+'), r'$1<redacted>'),
      });
      await writer.upsertRemote(url: profile.url, name: profile.name);
    }
    await HuijiaDebugLog.info('managed profile sync done', {'count': profiles.length});
    return unit;
  }
}
