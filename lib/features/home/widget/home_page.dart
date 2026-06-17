import 'dart:convert';
import 'dart:io';

import 'package:dartx/dartx.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/core/app_info/app_info_provider.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/core/router/bottom_sheets/bottom_sheets_notifier.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/features/account/model/managed_client_config.dart';
import 'package:hiddify/features/account/notifier/account_controller.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/home/widget/connection_button.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/active/active_proxy_delay_indicator.dart';
import 'package:hiddify/features/proxy/overview/proxies_overview_notifier.dart';
import 'package:hiddify/gen/assets.gen.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hiddify/utils/link_parsers.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:sliver_tools/sliver_tools.dart';

final homeProfileRoutesProvider = FutureProvider.family<List<HomeRouteInfo>, String>((ref, profileId) async {
  final repo = await ref.watch(profileRepositoryProvider.future);

  try {
    final generated = (await repo.generateConfig(profileId).run()).match((error) => throw error, (content) => content);
    final routes = _routesFromGeneratedConfig(generated);
    if (routes.isNotEmpty) return routes;
  } catch (_) {
    // Fall back to the stored profile body below.
  }

  final raw = await repo
      .getRawConfig(profileId)
      .run()
      .then((result) => result.match((error) => '', (content) => content));
  return _routesFromRawSubscription(raw);
});

final homeRouteDelayProvider = StateNotifierProvider.autoDispose
    .family<HomeRouteDelayNotifier, AsyncValue<Map<String, int>>, String>((ref, profileId) => HomeRouteDelayNotifier());

final homeSelectedRouteProvider = StateProvider.autoDispose.family<String?, String>((ref, profileId) => null);

class HomeRouteDelayNotifier extends StateNotifier<AsyncValue<Map<String, int>>> {
  HomeRouteDelayNotifier() : super(const AsyncData(<String, int>{}));

  Future<void> test(List<HomeRouteInfo> routes) async {
    if (state.isLoading) return;

    final previous = state.valueOrNull ?? const <String, int>{};
    final results = Map<String, int>.from(previous);
    final testableRoutes = routes.where((route) => route.target != null).toList(growable: false);
    if (testableRoutes.isEmpty) {
      state = AsyncData(results);
      return;
    }

    state = const AsyncLoading<Map<String, int>>();

    var cursor = 0;
    Future<void> worker() async {
      while (true) {
        final index = cursor++;
        if (index >= testableRoutes.length) return;
        final route = testableRoutes[index];
        final delay = await _tcpConnectDelay(route.target!, const Duration(seconds: 2));
        results[route.tag] = delay ?? _routeDelayTimeoutMs;
      }
    }

    final workerCount = testableRoutes.length < 8 ? testableRoutes.length : 8;
    await Future.wait(List.generate(workerCount, (_) => worker()));
    state = AsyncData(results);
  }
}

class HomeRouteInfo {
  const HomeRouteInfo({required this.tag, required this.name, required this.type, this.target});

  final String tag;
  final String name;
  final String type;
  final HomeRouteTarget? target;
}

class HomeRouteTarget {
  const HomeRouteTarget({required this.host, required this.port});

  final String host;
  final int port;
}

class HomePage extends HookConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final t = ref.watch(translationsProvider).requireValue;
    // final hasAnyProfile = ref.watch(hasAnyProfileProvider);
    final activeProfile = ref.watch(activeProfileProvider);
    final selectedRoute = ref.watch(homeSelectedRouteProvider(activeProfile.valueOrNull?.id ?? ''));

    useEffect(() {
      if (!ManagedClientConfig.enabled) return null;

      Future.microtask(() async {
        try {
          await ref.read(accountControllerProvider).syncProfiles();
          final profileId = ref.read(activeProfileProvider).valueOrNull?.id;
          if (profileId != null) {
            ref.invalidate(homeProfileRoutesProvider(profileId));
          }
        } catch (_) {
          // Manual sync still surfaces the error. Auto refresh should not interrupt opening the home page.
        }
      });

      return null;
    }, const []);

    return Scaffold(
      appBar: AppBar(
        // leading: (RootScaffold.stateKey.currentState?.hasDrawer ?? false) && showDrawerButton(context)
        //     ? DrawerButton(
        //         onPressed: () {
        //           RootScaffold.stateKey.currentState?.openDrawer();
        //         },
        //       )
        //     : null,
        title: Row(
          children: [
            Assets.images.logo.svg(height: 24),
            const Gap(8),
            const Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: Constants.appName),
                  TextSpan(text: " "),
                  WidgetSpan(child: AppVersionLabel(), alignment: PlaceholderAlignment.middle),
                ],
              ),
            ),
          ],
        ),
        actions: [
          // IconButton(
          //     onPressed: () => const QuickSettingsRoute().push(context),
          //     icon: const Icon(FluentIcons.options_24_filled),
          //     material: (context, platform) => MaterialIconButtonData(
          //           tooltip: t.config.quickSettings,
          //         )),
          // IconButton(
          //     onPressed: () => const AddProfileRoute().push(context),
          //     icon: const Icon(FluentIcons.add_circle_24_filled),
          //     material: (context, platform) => MaterialIconButtonData(
          //           tooltip: t.profile.add.buttonText,
          //         )),
          if (ManagedClientConfig.enabled) ...[
            IconButton(
              icon: Icon(Icons.sync_rounded, color: theme.colorScheme.primary),
              tooltip: '同步线路',
              onPressed: () async {
                try {
                  await ref.read(accountControllerProvider).syncProfiles();
                  final profileId = ref.read(activeProfileProvider).valueOrNull?.id ?? activeProfile.valueOrNull?.id;
                  if (profileId != null) {
                    ref.invalidate(homeProfileRoutesProvider(profileId));
                  }
                } catch (error) {
                  final message = ref.read(accountControllerProvider).errorMessage ?? error.toString();
                  await ref.read(dialogNotifierProvider.notifier).showCustomAlert(title: '同步线路失败', message: message);
                }
              },
            ),
            IconButton(
              icon: Icon(Icons.logout_rounded, color: theme.colorScheme.primary),
              tooltip: '退出登录',
              onPressed: () => ref.read(accountControllerProvider).logout(),
            ),
          ] else ...[
            Semantics(
              key: const ValueKey("profile_add_button"),
              label: t.pages.profiles.add,
              child: IconButton(
                icon: Icon(Icons.add_rounded, color: theme.colorScheme.primary),
                onPressed: () => ref.read(bottomSheetsNotifierProvider.notifier).showAddProfile(),
              ),
            ),
          ],
          const Gap(8),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          image: DecorationImage(
            image: const AssetImage('assets/images/world_map.png'), // Replace with your image path
            fit: BoxFit.cover,
            opacity: 0.09,
            colorFilter: theme.brightness == Brightness.dark
                ? ColorFilter.mode(Colors.white.withValues(alpha: .15), BlendMode.srcIn) //
                : ColorFilter.mode(
                    Colors.grey.withValues(alpha: 1),
                    BlendMode.srcATop,
                  ), // Apply white tint in dark mode
          ),
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: CustomScrollView(
              slivers: [
                MultiSliver(
                  children: [
                    switch (activeProfile) {
                      AsyncData(value: final profile?) => HomeRoutesPreview(profileId: profile.id),
                      _ => const SizedBox.shrink(),
                    },
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                ConnectionButton(
                                  selectedRouteTag: selectedRoute,
                                  onConnected: () async {
                                    final profileId = activeProfile.valueOrNull?.id;
                                    final outboundTag = ref.read(homeSelectedRouteProvider(profileId ?? ''));
                                    if (profileId == null || outboundTag == null) return;
                                    await _applySelectedRoute(ref: ref, outboundTag: outboundTag);
                                  },
                                ),
                                const ActiveProxyDelayIndicator(),
                              ],
                            ),
                          ),
                          const Gap(32),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class HomeRoutesPreview extends HookConsumerWidget {
  const HomeRoutesPreview({super.key, required this.profileId});

  final String profileId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectionState = ref.watch(
      connectionNotifierProvider.select((value) => value.valueOrNull ?? const Disconnected()),
    );

    if (connectionState.isConnected) {
      return _ConnectedHomeRoutesPreview(profileId: profileId);
    }

    return _ProfileRoutesPreview(profileId: profileId);
  }
}

class _ConnectedHomeRoutesPreview extends HookConsumerWidget {
  const _ConnectedHomeRoutesPreview({required this.profileId});

  final String profileId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final proxies = ref.watch(proxiesOverviewNotifierProvider);
    final groupTag = proxies.valueOrNull?.tag;

    useEffect(() {
      if (groupTag == null) return null;

      Future.microtask(() async {
        try {
          await ref.read(proxiesOverviewNotifierProvider.notifier).urlTest(groupTag, hapticFeedback: false);
        } catch (_) {
          // Automatic tests should not interrupt opening the home page.
        }
      });

      return null;
    }, [groupTag]);

    return proxies.when(
      data: (group) {
        final items = (group?.items ?? []).where(_isVisibleProxyInfo).toList();
        if (group == null || items.isEmpty) {
          return _ProfileRoutesPreview(profileId: profileId);
        }
        final selectedTag = _selectedProxyTag(group, items);
        return _HomeRoutesCard(
          count: items.length,
          onTestDelay: () async => await ref.read(proxiesOverviewNotifierProvider.notifier).urlTest(group.tag),
          children: [
            for (final proxy in items)
              _HomeProxyRouteRow(
                proxy: proxy,
                selected: selectedTag == proxy.tag,
                onTap: () async {
                  await ref.read(proxiesOverviewNotifierProvider.notifier).changeProxy(group.tag, proxy.tag);
                },
              ),
          ],
        );
      },
      error: (_, _) => _ProfileRoutesPreview(profileId: profileId),
      loading: () => const _HomeRoutesCard.loading(),
    );
  }
}

String? _selectedProxyTag(OutboundGroup group, List<OutboundInfo> items) {
  final selected = group.selected.trim();
  if (selected.isNotEmpty && items.any((item) => item.tag == selected)) {
    return selected;
  }

  for (final item in items) {
    if (item.isSelected) return item.tag;
  }
  return null;
}

class _ProfileRoutesPreview extends HookConsumerWidget {
  const _ProfileRoutesPreview({required this.profileId});

  final String profileId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final routes = ref.watch(homeProfileRoutesProvider(profileId));
    final selectedRoute = ref.watch(homeSelectedRouteProvider(profileId));
    final delays = ref.watch(homeRouteDelayProvider(profileId));
    final routeList = routes.valueOrNull;
    final routeSignature = routeList == null ? null : Object.hashAll(routeList.map((route) => route.tag));

    useEffect(() {
      if (routeList == null || routeList.isEmpty) return null;

      Future.microtask(() async {
        try {
          await ref.read(homeRouteDelayProvider(profileId).notifier).test(routeList);
        } catch (_) {
          // Automatic tests should not interrupt opening the home page.
        }
      });

      return null;
    }, [profileId, routeSignature]);

    return routes.when(
      data: (routes) {
        if (routes.isEmpty) {
          return _HomeRoutesCard.empty(onRefresh: () => ref.invalidate(homeProfileRoutesProvider(profileId)));
        }
        final delayValues = delays.valueOrNull ?? const <String, int>{};
        final sortedRoutes = _sortRoutesByDelay(routes, delayValues);
        return _HomeRoutesCard(
          count: routes.length,
          testing: delays.isLoading,
          onTestDelay: () async => await ref.read(homeRouteDelayProvider(profileId).notifier).test(routes),
          children: [
            for (final route in sortedRoutes)
              _HomeConfigRouteRow(
                route: route,
                delay: delayValues[route.tag],
                selected: selectedRoute == route.tag,
                onTap: () {
                  ref.read(homeSelectedRouteProvider(profileId).notifier).state = route.tag;
                },
              ),
          ],
        );
      },
      error: (_, _) => _HomeRoutesCard.empty(
        message: '线路读取失败',
        onRefresh: () => ref.invalidate(homeProfileRoutesProvider(profileId)),
      ),
      loading: () => const _HomeRoutesCard.loading(),
    );
  }
}

class _HomeRoutesCard extends StatelessWidget {
  const _HomeRoutesCard({required this.count, required this.children, this.onTestDelay, this.testing = false})
    : message = null,
      onRefresh = null;

  const _HomeRoutesCard.empty({this.message = '暂无线路', this.onRefresh})
    : count = 0,
      children = const [],
      onTestDelay = null,
      testing = false;

  const _HomeRoutesCard.loading()
    : count = null,
      children = const [],
      message = null,
      onRefresh = null,
      onTestDelay = null,
      testing = false;

  final int? count;
  final List<Widget> children;
  final String? message;
  final VoidCallback? onRefresh;
  final VoidCallback? onTestDelay;
  final bool testing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rowsHeight = (children.length * 52).clamp(52, 260).toDouble();

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      elevation: 0,
      color: theme.colorScheme.surfaceContainer,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 12, end: 4, top: 4, bottom: 4),
            child: Row(
              children: [
                Icon(Icons.route_rounded, size: 20, color: theme.colorScheme.primary),
                const Gap(8),
                Text('线路', style: theme.textTheme.titleSmall),
                if (count != null) ...[
                  const Gap(6),
                  Text(
                    '$count条',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
                const Spacer(),
                if (onTestDelay != null)
                  IconButton(
                    tooltip: '延迟测试',
                    onPressed: testing ? null : onTestDelay,
                    icon: testing
                        ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.speed_rounded),
                  ),
                if (onRefresh != null)
                  IconButton(tooltip: '刷新线路', onPressed: onRefresh, icon: const Icon(Icons.refresh_rounded)),
              ],
            ),
          ),
          Divider(height: 1, color: theme.colorScheme.outlineVariant),
          if (children.isNotEmpty)
            SizedBox(
              height: rowsHeight,
              child: ListView.separated(
                primary: false,
                padding: EdgeInsets.zero,
                itemCount: children.length,
                separatorBuilder: (context, index) => Divider(
                  height: 1,
                  indent: 48,
                  endIndent: 12,
                  color: theme.colorScheme.outlineVariant.withValues(alpha: .6),
                ),
                itemBuilder: (context, index) => children[index],
              ),
            )
          else if (message != null)
            SizedBox(
              height: 52,
              child: Center(
                child: Text(
                  message!,
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            )
          else
            const SizedBox(height: 52, child: Center(child: CircularProgressIndicator())),
        ],
      ),
    );
  }
}

class _HomeConfigRouteRow extends StatelessWidget {
  const _HomeConfigRouteRow({required this.route, this.delay, this.selected = false, this.onTap});

  final HomeRouteInfo route;
  final int? delay;
  final bool selected;
  final GestureTapCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return _HomeRouteRow(name: route.name, delay: delay, selected: selected, onTap: onTap);
  }
}

class _HomeProxyRouteRow extends StatelessWidget {
  const _HomeProxyRouteRow({required this.proxy, required this.selected, required this.onTap});

  final OutboundInfo proxy;
  final bool selected;
  final GestureTapCallback onTap;

  @override
  Widget build(BuildContext context) {
    final name = proxy.tagDisplay.trim().isNotEmpty ? proxy.tagDisplay.trim() : _cleanRouteName(proxy.tag);

    return _HomeRouteRow(name: name, delay: proxy.urlTestDelay, selected: selected, onTap: onTap);
  }
}

class _HomeRouteRow extends StatelessWidget {
  const _HomeRouteRow({required this.name, this.delay, this.selected = false, this.onTap});

  final String name;
  final int? delay;
  final bool selected;
  final GestureTapCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      minLeadingWidth: 24,
      leading: Icon(
        selected ? Icons.check_circle_rounded : Icons.circle_outlined,
        size: 20,
        color: selected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
      ),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: delay == null ? null : _HomeRouteDelay(delay!),
      selected: selected,
      selectedTileColor: theme.colorScheme.primaryContainer,
      onTap: onTap,
    );
  }
}

class _HomeRouteDelay extends StatelessWidget {
  const _HomeRouteDelay(this.delay);

  final int delay;

  @override
  Widget build(BuildContext context) {
    if (delay == 0) {
      return const SizedBox.shrink();
    }

    final timeout = delay >= _routeDelayTimeoutMs;
    final color = timeout
        ? Theme.of(context).colorScheme.error
        : switch (delay) {
            < 800 => Colors.green,
            < 1500 => Colors.deepOrangeAccent,
            _ => Colors.red,
          };

    return Text(timeout ? '超时' : '${delay}ms', style: TextStyle(color: color));
  }
}

class AppVersionLabel extends HookConsumerWidget {
  const AppVersionLabel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);

    final version = ref.watch(appInfoProvider).requireValue.presentVersion;
    if (version.isBlank) return const SizedBox();

    return Semantics(
      label: t.common.version,
      button: false,
      child: Container(
        decoration: BoxDecoration(color: theme.colorScheme.secondaryContainer, borderRadius: BorderRadius.circular(4)),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        child: Text(
          version,
          textDirection: TextDirection.ltr,
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSecondaryContainer),
        ),
      ),
    );
  }
}

Future<void> _applySelectedRoute({required WidgetRef ref, required String outboundTag}) async {
  try {
    final connected = await _waitForConnected(ref);
    if (!connected) return;

    final group = await _waitForProxyGroup(ref, outboundTag);
    if (group == null) {
      await ref
          .read(dialogNotifierProvider.notifier)
          .showCustomAlert(title: '线路选择失败', message: '连接后没有找到这条线路，请同步线路后再试。');
      return;
    }

    await ref.read(proxiesOverviewNotifierProvider.notifier).changeProxy(group.tag, outboundTag);
  } catch (error) {
    await ref.read(dialogNotifierProvider.notifier).showCustomAlert(title: '线路连接失败', message: error.toString());
  }
}

Future<bool> _waitForConnected(WidgetRef ref, {Duration timeout = const Duration(seconds: 12)}) async {
  final stopwatch = Stopwatch()..start();
  while (stopwatch.elapsed < timeout) {
    if (ref.read(connectionNotifierProvider).valueOrNull?.isConnected ?? false) {
      return true;
    }
    await Future.delayed(const Duration(milliseconds: 250));
  }
  return ref.read(connectionNotifierProvider).valueOrNull?.isConnected ?? false;
}

Future<OutboundGroup?> _waitForProxyGroup(
  WidgetRef ref,
  String outboundTag, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  final stopwatch = Stopwatch()..start();
  while (stopwatch.elapsed < timeout) {
    final group = ref.read(proxiesOverviewNotifierProvider).valueOrNull;
    if (group != null && group.items.any((item) => item.tag == outboundTag)) {
      return group;
    }
    await Future.delayed(const Duration(milliseconds: 250));
  }
  final group = ref.read(proxiesOverviewNotifierProvider).valueOrNull;
  if (group != null && group.items.any((item) => item.tag == outboundTag)) {
    return group;
  }
  return null;
}

List<HomeRouteInfo> _sortRoutesByDelay(List<HomeRouteInfo> routes, Map<String, int> delays) {
  if (delays.isEmpty) return routes;
  return routes.sortedWith((a, b) {
    final ad = delays[a.tag];
    final bd = delays[b.tag];
    if (ad == null && bd == null) return 0;
    if (ad == null) return 1;
    if (bd == null) return -1;
    return ad.compareTo(bd);
  });
}

List<HomeRouteInfo> _routesFromGeneratedConfig(String content) {
  try {
    final jsonObject = jsonDecode(content);
    if (jsonObject is! Map || jsonObject['outbounds'] is! List) {
      return const [];
    }

    final routes = <HomeRouteInfo>[];
    for (final outbound in jsonObject['outbounds'] as List) {
      if (outbound is! Map) continue;
      final tag = outbound['tag']?.toString().trim() ?? '';
      final type = outbound['type']?.toString().trim() ?? '';
      if (!_isRealOutbound(outbound, tag, type)) continue;
      routes.add(
        HomeRouteInfo(tag: tag, name: _cleanRouteName(tag), type: type, target: _targetFromOutbound(outbound)),
      );
    }
    return _dedupeRoutes(routes);
  } catch (_) {
    return const [];
  }
}

List<HomeRouteInfo> _routesFromRawSubscription(String content) {
  final decoded = safeDecodeBase64(content);
  final routes = <HomeRouteInfo>[];

  for (final rawLine in decoded.split(RegExp(r'\r?\n'))) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final route = _routeFromUriLine(line);
    if (route != null) routes.add(route);
  }

  return _dedupeRoutes(routes);
}

HomeRouteInfo? _routeFromUriLine(String line) {
  final schemeEnd = line.indexOf(':');
  if (schemeEnd <= 0) return null;

  final scheme = line.substring(0, schemeEnd).toLowerCase();
  if (!_proxyUriSchemes.contains(scheme)) return null;

  if (scheme == 'vmess') {
    final payload = line.substring('vmess://'.length).split(RegExp('[?#]')).first;
    final decoded = _decodeBase64Payload(payload);
    if (decoded != null) {
      try {
        final jsonObject = jsonDecode(decoded);
        if (jsonObject is Map) {
          final name = jsonObject['ps']?.toString().trim();
          if (name != null && name.isNotEmpty) {
            return HomeRouteInfo(tag: line, name: _cleanRouteName(name), type: scheme, target: _extractTcpTarget(line));
          }
        }
      } catch (_) {}
    }
  }

  final fragment = _uriFragment(line);
  if (fragment.isNotEmpty) {
    return HomeRouteInfo(tag: line, name: _cleanRouteName(fragment), type: scheme, target: _extractTcpTarget(line));
  }

  final uri = Uri.tryParse(line);
  final host = uri?.host.trim() ?? '';
  if (host.isNotEmpty) {
    return HomeRouteInfo(tag: line, name: host, type: scheme, target: _extractTcpTarget(line));
  }
  return null;
}

String _uriFragment(String line) {
  final fragmentStart = line.indexOf('#');
  if (fragmentStart == -1 || fragmentStart == line.length - 1) return '';
  final raw = line.substring(fragmentStart + 1);
  try {
    return Uri.decodeFull(raw).trim();
  } catch (_) {
    return raw.trim();
  }
}

String? _decodeBase64Payload(String payload) {
  try {
    var normalized = payload.trim().replaceAll('-', '+').replaceAll('_', '/');
    final remainder = normalized.length % 4;
    if (remainder != 0) {
      normalized = normalized.padRight(normalized.length + 4 - remainder, '=');
    }
    return utf8.decode(base64Decode(normalized));
  } catch (_) {
    return null;
  }
}

Future<int?> _tcpConnectDelay(HomeRouteTarget target, Duration timeout) async {
  Socket? socket;
  final stopwatch = Stopwatch()..start();
  try {
    socket = await Socket.connect(target.host, target.port, timeout: timeout);
    stopwatch.stop();
    return stopwatch.elapsedMilliseconds == 0 ? 1 : stopwatch.elapsedMilliseconds;
  } catch (_) {
    return null;
  } finally {
    socket?.destroy();
  }
}

HomeRouteTarget? _targetFromOutbound(Map<dynamic, dynamic> outbound) {
  final host = (outbound['server'] ?? outbound['address'] ?? outbound['host'] ?? '').toString().trim();
  final port = _readPort(outbound['server_port'] ?? outbound['serverPort'] ?? outbound['port']);
  if (host.isEmpty || port <= 0) return null;
  return HomeRouteTarget(host: host, port: port);
}

HomeRouteTarget? _extractTcpTarget(String line) {
  final trimmed = line.trim();
  final uri = Uri.tryParse(trimmed);
  if (uri == null || !uri.hasScheme) return null;

  final directTarget = _tcpTargetFromUri(uri);
  if (directTarget != null) return directTarget;

  return switch (uri.scheme.toLowerCase()) {
    'ss' || 'ssconf' => _extractShadowsocksTcpTarget(trimmed),
    'vmess' => _extractVmessTcpTarget(trimmed),
    _ => null,
  };
}

HomeRouteTarget? _tcpTargetFromUri(Uri uri) {
  if (!uri.hasAuthority || uri.host.isEmpty || !uri.hasPort || uri.port <= 0) return null;
  return HomeRouteTarget(host: uri.host, port: uri.port);
}

HomeRouteTarget? _extractShadowsocksTcpTarget(String line) {
  final body = _uriBody(line);
  if (body == null || body.isEmpty) return null;
  final decoded = _decodeBase64Payload(body) ?? body;
  final uri = Uri.tryParse(decoded.contains('://') ? decoded : 'ss://$decoded');
  return uri == null ? null : _tcpTargetFromUri(uri);
}

HomeRouteTarget? _extractVmessTcpTarget(String line) {
  try {
    final body = _uriBody(line);
    if (body == null || body.isEmpty) return null;
    final decoded = _decodeBase64Payload(body);
    if (decoded == null) return null;
    final jsonObject = jsonDecode(decoded);
    if (jsonObject is! Map) return null;
    final host = (jsonObject['add'] ?? jsonObject['address'] ?? jsonObject['host'] ?? '').toString().trim();
    final port = _readPort(jsonObject['port']);
    if (host.isEmpty || port <= 0) return null;
    return HomeRouteTarget(host: host, port: port);
  } catch (_) {
    return null;
  }
}

String? _uriBody(String line) {
  final separator = line.indexOf('://');
  if (separator < 0) return null;
  final bodyStart = separator + 3;
  final queryStart = line.indexOf(RegExp('[?#]'), bodyStart);
  if (queryStart < 0) return line.substring(bodyStart).trim();
  return line.substring(bodyStart, queryStart).trim();
}

int _readPort(Object? value) {
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

bool _isVisibleProxyInfo(OutboundInfo proxy) {
  if (proxy.isGroup) return false;
  return _isVisibleRouteTag(proxy.tag) && !_ignoredOutboundTypes.contains(proxy.type.trim().toLowerCase());
}

bool _isRealOutbound(Map<dynamic, dynamic> outbound, String tag, String type) {
  final normalizedType = type.trim().toLowerCase();
  if (!_isVisibleRouteTag(tag) || _ignoredOutboundTypes.contains(normalizedType)) {
    return false;
  }
  if (_proxyOutboundTypes.contains(normalizedType)) {
    return true;
  }
  return outbound.containsKey('server') || outbound.containsKey('server_port') || outbound.containsKey('serverPort');
}

bool _isVisibleRouteTag(String tag) {
  final normalized = tag.trim().toLowerCase();
  if (normalized.isEmpty || normalized.contains('§hide§')) return false;
  return !_ignoredRouteTags.contains(normalized);
}

String _cleanRouteName(String value) {
  final cleaned = value.replaceAll('§hide§', '').split(RegExp('\\s*§\\s*')).first.trim();
  return cleaned.isEmpty ? value.trim() : cleaned;
}

List<HomeRouteInfo> _dedupeRoutes(List<HomeRouteInfo> routes) {
  final seen = <String>{};
  final result = <HomeRouteInfo>[];
  for (final route in routes) {
    final key = route.tag.trim().isNotEmpty ? route.tag.trim() : route.name.trim();
    if (seen.add(key)) result.add(route);
  }
  return result;
}

const _ignoredOutboundTypes = {'selector', 'urltest', 'direct', 'block', 'dns', 'logical'};

const _routeDelayTimeoutMs = 65535;

const _ignoredRouteTags = {
  'select',
  'selector',
  'proxy',
  'urltest',
  'auto',
  'lowest',
  'balance',
  'direct',
  'direct-fragment',
  'bypass',
  'block',
  'dns',
  'dns-out',
  'fragment',
};

const _proxyOutboundTypes = {
  'shadowsocks',
  'vmess',
  'vless',
  'trojan',
  'hysteria',
  'hysteria2',
  'tuic',
  'ssh',
  'socks',
  'http',
  'wireguard',
  'shadowtls',
  'anytls',
  'mieru',
  'naive',
};

const _proxyUriSchemes = {
  'ss',
  'ssconf',
  'vmess',
  'vless',
  'trojan',
  'hysteria',
  'hysteria2',
  'hy2',
  'tuic',
  'ssh',
  'socks',
  'socks5',
  'wireguard',
};
