import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/router/bottom_sheets/bottom_sheets_notifier.dart';
import 'package:hiddify/features/account/model/managed_client_config.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class EmptyProfilesHomeBody extends HookConsumerWidget {
  const EmptyProfilesHomeBody({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;

    return SliverFillRemaining(
      hasScrollBody: false,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            ManagedClientConfig.enabled ? '登录后由服务端自动下发线路，请稍后同步。' : t.dialogs.noActiveProfile.msg,
            textAlign: TextAlign.center,
          ),
          const Gap(16),
          if (!ManagedClientConfig.enabled)
            ElevatedButton(
              onPressed: () => ref.read(bottomSheetsNotifierProvider.notifier).showAddProfile(),
              // icon: const Icon(FluentIcons.add_24_regular),
              child: Text(t.pages.profiles.add),
            ),
        ],
      ),
    );
  }
}

// class EmptyActiveProfileHomeBody extends HookConsumerWidget {
//   const EmptyActiveProfileHomeBody({super.key});

//   @override
//   Widget build(BuildContext context, WidgetRef ref) {
//     final t = ref.watch(translationsProvider).requireValue;

//     return SliverFillRemaining(
//       hasScrollBody: false,
//       child: Column(
//         mainAxisAlignment: MainAxisAlignment.center,
//         children: [
//           Text(t.home.noActiveProfileMsg),
//           const Gap(16),
//           OutlinedButton(
//             onPressed: () => const ProfilesOverviewRoute().push(context),
//             child: Text(t.profile.overviewPageTitle),
//           ),
//         ],
//       ),
//     );
//   }
// }
