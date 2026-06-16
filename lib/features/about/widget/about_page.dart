import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/core/app_info/app_info_provider.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/gen/assets.gen.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class AboutPage extends HookConsumerWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final appInfo = ref.watch(appInfoProvider).requireValue;

    return Scaffold(
      appBar: AppBar(title: Text(t.pages.about.title)),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Assets.images.logo.svg(width: 64, height: 64),
                const Gap(16),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(Constants.appName, style: Theme.of(context).textTheme.titleLarge),
                    const Gap(4),
                    Text("${t.common.version} ${appInfo.presentVersion}"),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.public_rounded),
            title: const Text('门户网站'),
            subtitle: const Text(Constants.portalUrl),
            trailing: const Icon(Icons.open_in_new_rounded),
            onTap: () async {
              await UriUtils.tryLaunch(Uri.parse(Constants.portalUrl));
            },
          ),
        ],
      ),
    );
  }
}
