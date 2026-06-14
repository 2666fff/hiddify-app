import 'package:fpdart/fpdart.dart';
import 'package:hiddify/features/account/data/account_api.dart';
import 'package:hiddify/features/account/model/account_session.dart';
import 'package:hiddify/features/account/service/managed_profiles_writer.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

final managedProfileSyncServiceProvider = Provider<ManagedProfileSyncService>((ref) {
  return ManagedProfileSyncService(
    api: ref.watch(accountApiProvider),
    ref: ref,
  );
});

class ManagedProfileSyncService {
  ManagedProfileSyncService({
    required AccountApi api,
    required Ref ref,
  }) : _api = api,
       _ref = ref;

  final AccountApi _api;
  final Ref _ref;

  Future<Unit> sync(AccountSession session) async {
    final profiles = await _api.fetchProfiles(session);
    final repository = await _ref.read(profileRepositoryProvider.future);
    final writer = ManagedProfilesWriter(repository);
    for (final profile in profiles) {
      await writer.upsertRemote(url: profile.url, name: profile.name);
    }
    return unit;
  }
}
