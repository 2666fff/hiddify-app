class ManagedProfile {
  const ManagedProfile({
    required this.url,
    required this.name,
  });

  final String url;
  final String name;

  factory ManagedProfile.fromJson(Map<String, dynamic> json) {
    return ManagedProfile(
      url: (json['url'] ?? json['subscriptionUrl'] ?? json['profileUrl'] ?? '').toString(),
      name: (json['name'] ?? json['title'] ?? 'Huijia VPN').toString(),
    );
  }
}
