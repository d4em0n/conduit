import 'package:conduit_core/features/navigation/models/sidebar_navigation_model.dart';
import 'package:conduit_core/features/navigation/providers/sidebar_active_tab_provider.dart';
import 'package:conduit_core/features/terminal/providers/terminal_providers.dart';
import 'package:conduit_core/features/terminal/models/terminal_models.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../../shared/widgets/platform_ui/vocabulary.dart';
import '../../terminal/widgets/authenticated_webui_page.dart';

class TerminalDocumentCover extends ConsumerStatefulWidget {
  const TerminalDocumentCover({super.key, required this.file});
  final Map<String, dynamic> file;

  @override
  ConsumerState<TerminalDocumentCover> createState() =>
      _TerminalDocumentCoverState();
}

class _TerminalDocumentCoverState extends ConsumerState<TerminalDocumentCover> {
  bool _opening = false;

  Future<void> _open() async {
    if (_opening) return;
    setState(() => _opening = true);
    final epoch = ref.read(openWebUiAuthSessionEpochProvider);
    final conversationId = ref.read(activeConversationProvider)?.id;
    final fileId = widget.file['id'];
    bool current() =>
        mounted &&
        widget.file['id'] == fileId &&
        ref.read(activeConversationProvider)?.id == conversationId &&
        identical(epoch, ref.read(openWebUiAuthSessionEpochProvider));
    try {
      final selector = widget.file['terminal_selector'] as String;
      final path = widget.file['path'] as String;
      final chat = ref.read(activeConversationProvider);
      final page = widget.file['page'];
      if (!selector.contains('://')) {
        final shown = await AuthenticatedWebUiPage.open(
          context,
          fileName: widget.file['name'] as String,
          target: {
            'terminal_id': selector,
            'path': path,
            if (chat != null && isSavedTerminalChatScopeId(chat.id))
              'chat_id': chat.id,
            if (page is int) 'page': '$page',
          },
          isCurrent: current,
        );
        if (shown || !current()) return;
      }
      // Servers without the optional page retain the native Terminal preview.
      final servers = await ref.read(terminalAvailableServersProvider.future);
      if (!current()) return;
      for (final server in servers) {
        if (server.selectionId != selector) continue;
        await ref.read(terminalSelectionControllerProvider).select(server);
        if (!current()) return;
        ref.read(sidebarActiveTabProvider.notifier).set(SidebarTabId.terminal);
        ref
            .read(terminalSidebarPanelProvider.notifier)
            .setPanel(TerminalSidebarPanel.files);
        ref
            .read(terminalDisplayFileProvider.notifier)
            .show(path, page: page is int ? page : null);
        return;
      }
      if (mounted && current()) {
        AdaptiveSnackBar.show(
          context,
          message: AppLocalizations.of(context)!.terminalPreviewUnavailable,
        );
      }
    } catch (_) {
      if (mounted && current()) {
        AdaptiveSnackBar.show(
          context,
          message: AppLocalizations.of(context)!.terminalFailedToLoadFiles,
        );
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 300,
    child: AdaptiveButton.child(
      onPressed: _opening ? null : _open,
      style: AdaptiveButtonStyle.tinted,
      padding: const EdgeInsets.all(Spacing.md),
      child: Row(
        children: [
          const Icon(Icons.description_outlined, size: 36),
          const SizedBox(width: Spacing.md),
          Expanded(
            child: Text(
              widget.file['name'] as String,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: Spacing.sm),
          const Icon(Icons.open_in_full, size: 18),
        ],
      ),
    ),
  );
}
