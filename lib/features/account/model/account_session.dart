class AccountSession {
  const AccountSession({
    required this.token,
    required this.username,
  });

  final String token;
  final String username;

  bool get isAuthenticated => token.isNotEmpty;
}
