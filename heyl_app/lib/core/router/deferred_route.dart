import 'package:flutter/material.dart';

import '../../l10n/generated/l10n.dart';

import '../theme/app_colors.dart';

/// Widget that handles deferred/lazy loading of routes.
///
/// Use this to wrap routes that should be code-split and loaded on-demand
/// rather than included in the initial bundle.
///
/// Example usage in app_router.dart:
/// ```dart
/// import 'list_detail_screen.dart' deferred as list_detail;
///
/// GoRoute(
///   path: '/lists/:listId',
///   pageBuilder: (context, state) => NoTransitionPage(
///     child: DeferredRouteLoader(
///       loadLibrary: list_detail.loadLibrary,
///       builder: () => list_detail.ListDetailScreen(
///         listId: state.pathParameters['listId']!,
///       ),
///     ),
///   ),
/// ),
/// ```
class DeferredRouteLoader extends StatefulWidget {
  /// Function that loads the deferred library (e.g., `myScreen.loadLibrary`)
  final Future<void> Function() loadLibrary;

  /// Builder function that creates the actual widget after library is loaded
  final Widget Function() builder;

  /// Optional custom loading widget
  final Widget? loadingWidget;

  /// Optional custom error widget builder
  final Widget Function(Object error)? errorBuilder;

  const DeferredRouteLoader({
    super.key,
    required this.loadLibrary,
    required this.builder,
    this.loadingWidget,
    this.errorBuilder,
  });

  @override
  State<DeferredRouteLoader> createState() => _DeferredRouteLoaderState();
}

class _DeferredRouteLoaderState extends State<DeferredRouteLoader> {
  late Future<void> _loadFuture;

  @override
  void initState() {
    super.initState();
    _loadFuture = widget.loadLibrary();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _loadFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.done) {
          if (snapshot.hasError) {
            return widget.errorBuilder?.call(snapshot.error!) ??
                _DefaultErrorWidget(error: snapshot.error.toString());
          }
          return widget.builder();
        }
        return widget.loadingWidget ?? const _DefaultLoadingWidget();
      },
    );
  }
}

class _DefaultLoadingWidget extends StatelessWidget {
  const _DefaultLoadingWidget();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}

class _DefaultErrorWidget extends StatelessWidget {
  final String error;

  const _DefaultErrorWidget({required this.error});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 48, color: AppColors.error),
              const SizedBox(height: 16),
              Text(
                'Failed to load page',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                error,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(Lt.of(context).commonBack),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
