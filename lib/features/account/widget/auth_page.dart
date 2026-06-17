import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/features/account/model/managed_client_config.dart';
import 'package:hiddify/features/account/notifier/account_controller.dart';
import 'package:hiddify/utils/uri_utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class AuthPage extends HookConsumerWidget {
  const AuthPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(accountControllerProvider);
    final usernameController = useTextEditingController();
    final passwordController = useTextEditingController();
    final formKey = useMemoized(GlobalKey<FormState>.new);

    ref.listen(accountControllerProvider, (previous, next) {
      if (next.isAuthenticated && context.mounted) {
        context.go('/home');
      }
    });

    Future<void> submit() async {
      if (!(formKey.currentState?.validate() ?? false)) return;
      try {
        await controller.login(usernameController.text.trim(), passwordController.text);
      } catch (_) {
        // Error text is kept in AccountController and rendered below the form.
      }
    }

    final theme = Theme.of(context);
    final username = usernameController.text.trim();
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Form(
              key: formKey,
              child: AutofillGroup(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(Icons.shield_outlined, size: 48, color: theme.colorScheme.primary),
                    const Gap(16),
                    Text('登录 回家看看', textAlign: TextAlign.center, style: theme.textTheme.headlineSmall),
                    const Gap(6),
                    Text(
                      '服务端校验账号后会自动下发可用线路',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                    const Gap(24),
                    TextFormField(
                      controller: usernameController,
                      enabled: !controller.isLoading,
                      autofillHints: const [AutofillHints.username],
                      decoration: const InputDecoration(
                        labelText: '账号',
                        prefixIcon: Icon(Icons.person_outline_rounded),
                      ),
                      validator: (value) => (value == null || value.trim().isEmpty) ? '请输入账号' : null,
                      textInputAction: TextInputAction.next,
                    ),
                    const Gap(12),
                    TextFormField(
                      controller: passwordController,
                      enabled: !controller.isLoading,
                      obscureText: true,
                      autofillHints: const [AutofillHints.password],
                      decoration: const InputDecoration(labelText: '密码', prefixIcon: Icon(Icons.lock_outline_rounded)),
                      validator: (value) => (value == null || value.length < 6) ? '密码至少 6 位' : null,
                      onFieldSubmitted: (_) => submit(),
                    ),
                    if (controller.errorMessage case final message?) ...[
                      const Gap(12),
                      Text(message, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
                      if (_isRechargeMessage(message)) ...[
                        const Gap(8),
                        OutlinedButton.icon(
                          onPressed: controller.isLoading
                              ? null
                              : () => UriUtils.tryLaunch(Uri.parse('${Constants.portalUrl}/#recharge')),
                          icon: const Icon(Icons.payments_outlined),
                          label: const Text('查看充值介绍'),
                        ),
                        const Gap(6),
                        Text(
                          username.isEmpty ? '充值时请在备注里填写用户名，到账后会按金额开通对应天数。' : '充值时请在备注里填写用户名：$username，到账后会按金额开通对应天数。',
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ],
                    const Gap(20),
                    FilledButton.icon(
                      onPressed: controller.isLoading ? null : submit,
                      icon: controller.isLoading
                          ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.login_rounded),
                      label: const Text('登录并同步线路'),
                    ),
                    const Gap(8),
                    TextButton(
                      onPressed: controller.isLoading
                          ? null
                          : () => UriUtils.tryLaunch(Uri.parse('${Constants.portalUrl}/#account')),
                      child: const Text('没有账号，网页注册'),
                    ),
                    const Gap(16),
                    Text(
                      'API: ${ManagedClientConfig.apiBaseUrl}',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

bool _isRechargeMessage(String message) {
  return message.contains('会员已过期') || message.contains('请充值');
}
