import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/features/account/data/account_api.dart';
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
    final captchaAnswerController = useTextEditingController();
    final isRegister = useState(false);
    final captcha = useState<CaptchaChallenge?>(null);
    final captchaError = useState<String?>(null);
    final isCaptchaLoading = useState(false);
    final formKey = useMemoized(GlobalKey<FormState>.new);

    Future<void> refreshCaptcha() async {
      if (!isRegister.value || isCaptchaLoading.value) return;
      isCaptchaLoading.value = true;
      captchaError.value = null;
      try {
        captcha.value = await ref.read(accountApiProvider).fetchCaptcha();
        captchaAnswerController.clear();
      } catch (_) {
        captcha.value = null;
        captchaError.value = '验证码加载失败，请稍后重试';
      } finally {
        isCaptchaLoading.value = false;
      }
    }

    useEffect(() {
      if (isRegister.value) {
        refreshCaptcha();
      }
      return null;
    }, [isRegister.value]);

    ref.listen(accountControllerProvider, (previous, next) {
      if (next.isAuthenticated && context.mounted) {
        context.go('/home');
      }
    });

    Future<void> submit() async {
      if (!(formKey.currentState?.validate() ?? false)) return;
      try {
        if (isRegister.value) {
          final captchaChallenge = captcha.value;
          if (captchaChallenge == null) {
            captchaError.value = '请先刷新验证码';
            return;
          }
          if (captchaAnswerController.text.trim().isEmpty) {
            captchaError.value = '请输入验证码';
            return;
          }
          await controller.register(
            usernameController.text.trim(),
            passwordController.text,
            captchaToken: captchaChallenge.token,
            captchaAnswer: captchaAnswerController.text.trim(),
          );
        } else {
          await controller.login(usernameController.text.trim(), passwordController.text);
        }
      } catch (_) {
        // Error text is kept in AccountController and rendered below the form.
        if (isRegister.value) {
          await refreshCaptcha();
        }
      }
    }

    final theme = Theme.of(context);
    final captchaBytes = _captchaBytes(captcha.value?.imageDataUrl);
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
                    Text(
                      isRegister.value ? '注册 回家看看' : '登录 回家看看',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall,
                    ),
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
                    if (isRegister.value) ...[
                      const Gap(12),
                      Row(
                        children: [
                          Expanded(
                            child: Container(
                              height: 54,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                border: Border.all(color: theme.colorScheme.outlineVariant),
                                borderRadius: BorderRadius.circular(12),
                                color: theme.colorScheme.surfaceContainerHighest,
                              ),
                              child: isCaptchaLoading.value
                                  ? const SizedBox.square(
                                      dimension: 22,
                                      child: CircularProgressIndicator(strokeWidth: 2),
                                    )
                                  : captchaBytes != null
                                  ? Image.memory(captchaBytes, fit: BoxFit.contain)
                                  : Text(
                                      '验证码加载失败',
                                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                                    ),
                            ),
                          ),
                          const Gap(8),
                          IconButton.filledTonal(
                            onPressed: controller.isLoading || isCaptchaLoading.value ? null : refreshCaptcha,
                            icon: const Icon(Icons.refresh_rounded),
                            tooltip: '刷新验证码',
                          ),
                        ],
                      ),
                      const Gap(8),
                      TextFormField(
                        controller: captchaAnswerController,
                        enabled: !controller.isLoading && !isCaptchaLoading.value,
                        decoration: const InputDecoration(
                          labelText: '验证码',
                          prefixIcon: Icon(Icons.verified_user_outlined),
                        ),
                        validator: (value) => (value == null || value.trim().isEmpty) ? '请输入验证码' : null,
                        onFieldSubmitted: (_) => submit(),
                      ),
                      if (captchaError.value case final message?) ...[
                        const Gap(8),
                        Text(message, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
                      ],
                    ],
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
                          : Icon(isRegister.value ? Icons.person_add_alt_1_rounded : Icons.login_rounded),
                      label: Text(isRegister.value ? '注册并同步线路' : '登录并同步线路'),
                    ),
                    const Gap(8),
                    TextButton(
                      onPressed: controller.isLoading
                          ? null
                          : () {
                              captchaError.value = null;
                              isRegister.value = !isRegister.value;
                            },
                      child: Text(isRegister.value ? '已有账号，去登录' : '没有账号，去注册'),
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

Uint8List? _captchaBytes(String? dataUrl) {
  if (dataUrl == null || dataUrl.isEmpty) return null;
  final commaIndex = dataUrl.indexOf(',');
  if (commaIndex < 0) return null;
  try {
    return base64Decode(dataUrl.substring(commaIndex + 1));
  } catch (_) {
    return null;
  }
}

bool _isRechargeMessage(String message) {
  return message.contains('会员已过期') || message.contains('请充值');
}
