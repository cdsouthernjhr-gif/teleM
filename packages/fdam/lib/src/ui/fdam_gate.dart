// Shows the setup screen until required assets are installed, then [child].
// Optional assets never block. Runs an update check once when mounted.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../asset_manager.dart';
import 'asset_setup_screen.dart';
import 'providers.dart';

class FdamGate extends ConsumerStatefulWidget {
  const FdamGate({
    super.key,
    required this.child,
    this.logo,
    this.appName = '',
    this.allowContinueWithoutManifest = false,
    this.checkOnStart = true,
  });

  final Widget child;
  final Widget? logo;
  final String appName;

  /// Let the user into the app when the manifest cannot be loaded and no
  /// cache exists (use when the app works without extra assets).
  final bool allowContinueWithoutManifest;
  final bool checkOnStart;

  @override
  ConsumerState<FdamGate> createState() => _FdamGateState();
}

class _FdamGateState extends ConsumerState<FdamGate> {
  bool _bypass = false;
  bool _passedOnce = false;

  @override
  void initState() {
    super.initState();
    if (widget.checkOnStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ref.read(assetManagerProvider).checkForUpdates();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final snap = ref.watch(fdamSnapshotProvider);
    final open = _bypass ||
        snap.phase == FdamPhase.disabled ||
        snap.requiredReady ||
        // Once inside, a later check never throws the user out unless a
        // required asset is really missing.
        (_passedOnce && snap.plan == null);
    if (open) {
      _passedOnce = true;
      return widget.child;
    }
    if (snap.plan == null && (snap.phase == FdamPhase.starting || snap.phase == FdamPhase.checking)) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return AssetSetupScreen(
      logo: widget.logo,
      appName: widget.appName,
      onContinueWithoutAssets: widget.allowContinueWithoutManifest ? () => setState(() => _bypass = true) : null,
    );
  }
}
