import 'package:fpdart/fpdart.dart';
import 'package:hiddify/features/profile/data/profile_repository.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';

class ManagedProfilesWriter {
  ManagedProfilesWriter(this._profileRepository);

  final ProfileRepository _profileRepository;

  Future<Unit> upsertRemote({required String url, required String name}) async {
    return await _profileRepository
        .upsertRemote(url, userOverride: UserOverride(name: name))
        .getOrElse((error) => throw error)
        .run();
  }
}
