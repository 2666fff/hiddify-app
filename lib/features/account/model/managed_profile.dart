import 'package:hiddify/core/model/constants.dart';

class ManagedProfile {
  const ManagedProfile({required this.url, required this.name});

  final String url;
  final String name;

  factory ManagedProfile.fromJson(Map<String, dynamic> json) {
    return ManagedProfile(
      url:
          (json['url'] ??
                  json['subscriptionUrl'] ??
                  json['subscription_url'] ??
                  json['subscribeUrl'] ??
                  json['subscribe_url'] ??
                  json['profileUrl'] ??
                  json['profile_url'] ??
                  json['sublink'] ??
                  json['link'] ??
                  json['uri'] ??
                  '')
              .toString(),
      name: Constants.normalizeAppDisplayName((json['name'] ?? json['title'] ?? Constants.appName).toString()),
    );
  }
}
