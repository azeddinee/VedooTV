import 'dart:async';
import 'dart:math';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:open_iptv/shared/utils/motion.dart';
import 'package:open_iptv/telemetry/consent_dialog.dart';
import 'package:open_iptv/core/models/source.dart';
import 'package:open_iptv/core/providers/theme_providers.dart';
import 'package:open_iptv/core/services/profile_service.dart';
import 'package:open_iptv/core/services/source_manager.dart';
import 'package:open_iptv/core/services/tv_text_input.dart';
import 'package:open_iptv/core/storage/preferences.dart';
import 'package:open_iptv/features/settings/backup_screen.dart';
import 'package:open_iptv/shared/theme/app_theme.dart';
import 'package:open_iptv/shared/utils/friendly_error.dart';
import 'package:open_iptv/shared/widgets/pin_field.dart';
import 'package:open_iptv/shared/widgets/tv_focusable.dart';
import 'package:open_iptv/shared/widgets/language_picker.dart';
import 'package:open_iptv/l10n/gen/app_localizations.dart';
import 'package:open_iptv/ui/platform_helper.dart';

/// The first word of [name], or empty when no name was entered.
String _firstName(String name) =>
    name.trim().isNotEmpty ? name.trim().split(' ').first : '';

/// A lighter tint of [color], used for the wizard's gradient accents.
Color _lighten(Color color, [double amount = 0.3]) =>
    Color.lerp(color, Colors.white, amount)!;

// ---------------------------------------------------------------------------
// SetupWizardScreen
// ---------------------------------------------------------------------------

/// First-run setup (profile → PIN → playlist), or — with [addPlaylistOnly]
/// — just the playlist steps, for adding another playlist to an existing
/// install (Settings → Playlists → Add Playlist, or after every playlist has
/// been deleted).
class SetupWizardScreen extends ConsumerStatefulWidget {
  const SetupWizardScreen({super.key, this.addPlaylistOnly = false});

  final bool addPlaylistOnly;

  @override
  ConsumerState<SetupWizardScreen> createState() => _SetupWizardScreenState();
}

class _SetupWizardScreenState extends ConsumerState<SetupWizardScreen>
    with TickerProviderStateMixin {
  // Playlist-only mode starts directly at the Xtream credentials page.
  static const _credentialsPage = 4;
  late final _pageController = PageController(initialPage: _firstPage);

  // Native Back. On a first run the wizard is the root route, with no shell
  // to take Back, and the system's own Back left the app from any page.
  // Registering here (the same channel the shell uses) steps back a page
  // instead. When the wizard is opened from Settings the shell is still
  // alive underneath and already forwards Back to the route's PopScope.
  static const _backChannel = MethodChannel('openiptv/back');

  int get _firstPage => widget.addPlaylistOnly ? _credentialsPage : 0;

  // The page being shown — Back steps through these before leaving.
  late int _page = _firstPage;

  // Profile state
  final _nameCtrl = TextEditingController();
  final _nameFocusNode = FocusNode();
  // Each explicitly requestFocus()'d from _goToPage at the moment the
  // wizard actually navigates to that page — see _nameFocusNode's original
  // comment and TvFocusable.focusNode's doc for why plain `autofocus: true`
  // doesn't work reliably on this PageView (every page is built up front,
  // so autofocus fires far too early and loses the initial-focus race to
  // whichever page happened to build first).
  final _startFocusNode = FocusNode();
  final _pin1FocusNode = FocusNode();
  final _codeFocusNode = FocusNode();
  String _avatarEmoji = '🧑';
  Color _accentColor = AppTheme.defaultAccent;
  String _pin = '';

  // Xtream login details. The app builds the server URL from the customer's code.
  final _xtreamCodeCtrl = TextEditingController();
  final _xtreamUserCtrl = TextEditingController();
  final _xtreamPassCtrl = TextEditingController();
  final _epgUrlCtrl = TextEditingController();
  bool _passVisible = false;

  // Loading / all-set state
  bool _isLoading = false;
  bool _restoring = false;
  String? _errorMessage;
  /// Null until the service reports progress; the loading page then shows
  /// the localized "Connecting…".
  String? _progressMessage;

  // All-set animations
  late final AnimationController _checkCtrl;
  late final Animation<double> _checkScale;
  late final AnimationController _sparkleCtrl;
  late final Animation<double> _sparkleAngle;

  @override
  void initState() {
    super.initState();
    _checkCtrl = AnimationController(
      vsync: this,
      duration: motionDuration(const Duration(milliseconds: 800)),
    );
    _checkScale = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _checkCtrl, curve: Curves.elasticOut),
    );
    _sparkleCtrl = AnimationController(
      vsync: this,
      duration: motionDuration(const Duration(milliseconds: 3000)),
    );
    loopUnlessReduced(_sparkleCtrl);
    _sparkleAngle = Tween(begin: 0.0, end: 2 * pi).animate(_sparkleCtrl);

    if (!widget.addPlaylistOnly) {
      _backChannel.setMethodCallHandler((call) async {
        if (call.method == 'backPressed') _onNativeBack();
      });
      unawaited(_backChannel.invokeMethod('setBlocked', true).catchError((_) {}));
    }

    if (widget.addPlaylistOnly) {
      // Existing install — keep the user's accent, and give the D-pad its
      // starting point on the first page shown.
      _accentColor = ref.read(accentColorProvider);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _codeFocusNode.requestFocus();
      });
    }

    // Autofocus on a TextField at page-transition time (rather than the
    // widget's own `autofocus: true`) is notoriously unreliable at getting
    // Android's soft keyboard to actually show — the IME often only shows
    // for a focus change it can tie to a genuine user gesture. Nudging it
    // explicitly here (also re-armed in the focus listener below) is the
    // standard workaround.
    _nameFocusNode.onKeyEvent = (node, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      // TextField swallows arrow keys for cursor movement, which — with
      // nothing to move to in a single-line field — otherwise traps D-pad
      // focus inside it with no way out (reported directly by a user
      // testing on a real Android TV remote).
      final key = event.logicalKey;
      final ctx = node.context;
      if (ctx == null) return KeyEventResult.ignored;
      if (key == LogicalKeyboardKey.arrowDown) {
        FocusScope.of(ctx).nextFocus();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp) {
        FocusScope.of(ctx).previousFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };
    _nameFocusNode.addListener(() {
      if (_nameFocusNode.hasFocus) {
        SystemChannels.textInput.invokeMethod('TextInput.show');
      }
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    _checkCtrl.dispose();
    _sparkleCtrl.dispose();
    _nameCtrl.dispose();
    _nameFocusNode.dispose();
    _startFocusNode.dispose();
    _pin1FocusNode.dispose();
    _codeFocusNode.dispose();
    _xtreamCodeCtrl.dispose();
    _xtreamUserCtrl.dispose();
    _xtreamPassCtrl.dispose();
    _epgUrlCtrl.dispose();
    super.dispose();
  }

  void _onNativeBack() {
    if (!mounted || _page >= 5) return;
    if (_page <= _firstPage) {
      // Nothing earlier: leave, as the system's Back would.
      unawaited(_backChannel.invokeMethod('systemBack').catchError((_) {}));
      return;
    }
    _goToPage(_page - 1);
  }

  void _goToPage(int page, {bool requestFocus = true}) {
    setState(() => _page = page);
    _pageController.animateToPage(
      page,
      duration: motionDuration(const Duration(milliseconds: 380)),
      curve: Curves.easeInOutCubic,
    );
    // PageView keeps every page built at once, so each page's own controls
    // exist (and could otherwise steal focus) well before that page is
    // actually shown — only request focus once we're actually navigating
    // to it, on whichever control should be the D-pad starting point there.
    final focusNode = switch (page) {
      0 => _startFocusNode,
      1 => _nameFocusNode,
      2 => _pin1FocusNode,
      4 => _codeFocusNode,
      _ => null,
    };
    if (requestFocus && focusNode != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        focusNode.requestFocus();
      });
      // Once the slide has finished, make sure the D-pad has a starting
      // point: a request made while the page was still being switched in can
      // be dropped.
      Future.delayed(const Duration(milliseconds: 500), () {
        if (!mounted || _page != page || focusNode.hasFocus) return;
        focusNode.requestFocus();
      });
    }
  }

  Future<void> _submitSource() async {
    final l10n = AppLocalizations.of(context);
    FocusScope.of(context).unfocus();

    final code = _xtreamCodeCtrl.text.trim().toLowerCase();
    final missing = [
      if (code.isEmpty) l10n.wizardFieldUniqueCode,
      if (_xtreamUserCtrl.text.trim().isEmpty) l10n.wizardFieldUsername,
      if (_xtreamPassCtrl.text.trim().isEmpty) l10n.wizardFieldPassword,
    ];
    if (missing.isNotEmpty) {
      final list = missing.length == 1
          ? missing.first
          : l10n.wizardListAnd(
              missing.sublist(0, missing.length - 1).join(', '),
              missing.last);
      setState(() => _errorMessage = l10n.wizardEnterMissing(list));
      return;
    }
    // A customer code must be a single DNS label, not a URL or hostname.
    if (!RegExp(r'^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$').hasMatch(code)) {
      setState(() => _errorMessage = l10n.wizardInvalidUniqueCode);
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _progressMessage = null;
    });
    _goToPage(5);

    try {
      final manager = ref.read(sourceManagerProvider);
      final host = 'http://$code.tvway.pro';
      final epgUrl = _epgUrlCtrl.text.trim().isEmpty
          ? null
          : _epgUrlCtrl.text.trim();

      void onProgress(String msg) {
        if (mounted) setState(() => _progressMessage = msg);
      }

      await manager.addSource(
        nickname: 'VedooTV',
        type: SourceType.xtream,
        xtreamHost: host,
        xtreamUsername: _xtreamUserCtrl.text.trim(),
        xtreamPassword: _xtreamPassCtrl.text.trim(),
        epgUrl: epgUrl,
        onProgress: onProgress,
      );

      if (!mounted) return;

      if (!widget.addPlaylistOnly) {
        final prefs = await ref.read(appPreferencesProvider.future);
        final db = ref.read(appDatabaseProvider);
        final profileSvc = ProfileService(db: db, prefsSnapshot: prefs);
        await profileSvc.createProfile(
          name: _nameCtrl.text.trim(),
          avatarEmoji: _avatarEmoji,
          pin: _pin.isEmpty ? null : _pin,
          isAdmin: true,
          accentColor: AppTheme.hexFromAccent(_accentColor),
        );
        ref.invalidate(activeProfileProvider);
        ref.invalidate(allProfilesProvider);
        await prefs.setAccentColor(AppTheme.hexFromAccent(_accentColor));
        ref.read(accentColorProvider.notifier).state = _accentColor;
      }

      if (!mounted) return;
      ref.invalidate(allSourcesProvider);

      if (!widget.addPlaylistOnly) {
        await askStatsConsentOnce(context, ProviderScope.containerOf(context));
        if (!mounted) return;
      }

      _goToPage(6);
      unawaited(_checkCtrl.forward());
      await Future.delayed(const Duration(seconds: 3));
      if (mounted) _finish();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = friendlySourceErrorMessage(e, l10n);
      });
      _goToPage(_credentialsPage,
          requestFocus: PlatformHelper.isTV(context));
    }
  }

  /// Welcome page → "Restore from a backup": brings back profiles, playlists
  /// and settings, then downloads each playlist's channels (a backup holds
  /// playlist logins, not their contents) on the loading page.
  Future<void> _restoreFromBackup() async {
    final summary = await restoreBackupFromFile(context, ref);
    if (summary == null || !mounted) return;

    final db = ref.read(appDatabaseProvider);
    final prefs = await ref.read(appPreferencesProvider.future);
    final profiles = await db.getAllProfiles();
    final sources = await db.getAllSources();
    if (profiles.isEmpty || sources.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(AppLocalizations.of(context).wizardRestoreEmpty)));
      return;
    }
    // One profile: use it. Several: start on an admin one (the person
    // restoring holds the whole backup anyway); the picker is available
    // from Settings afterwards.
    final active = profiles.length == 1
        ? profiles.first
        : profiles.firstWhere((p) => p.isAdmin, orElse: () => profiles.first);
    await prefs.setActiveProfileId(active.id);
    ref.invalidate(activeProfileProvider);
    ref.read(accentColorProvider.notifier).state =
        AppTheme.accentFromHex(prefs.accentColor);
    if (!mounted) return;

    setState(() {
      _isLoading = true;
      _restoring = true;
      // Show the restored accent, not the wizard's default.
      _accentColor = AppTheme.accentFromHex(prefs.accentColor);
      _progressMessage = null;
    });
    _goToPage(5);
    final manager = ref.read(sourceManagerProvider);
    final l10n = AppLocalizations.of(context);
    for (final (i, source) in sources.indexed) {
      final label = sources.length > 1
          ? l10n.wizardRestoreProgressItem(source.nickname, i + 1, sources.length)
          : source.nickname;
      try {
        await manager.refreshSource(source, onProgress: (msg) {
          if (mounted) setState(() =>
              _progressMessage = l10n.wizardRestoreProgressLine(label, msg));
        });
      } catch (e) {
        // One unreachable playlist mustn't block the rest; it can be
        // refreshed from Settings later.
        debugPrint('[OTV-restore] refresh failed for ${source.nickname}: $e');
      }
    }
    if (!mounted) return;
    ref.invalidate(allSourcesProvider);
    context.go('/live');
  }

  /// Back to wherever the wizard was opened from (Settings), or into the
  /// app when it's the root route (first run, or no playlists left).
  void _finish() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/live');
    }
  }

  @override
  Widget build(BuildContext context) {
    final addOnly = widget.addPlaylistOnly;
    // Step dots count only the pages this mode actually shows.
    final totalSteps = addOnly ? 1 : 3;
    // Back (remote, gesture, system button) goes one step back, like the
    // on-screen arrow; only from the first page does it leave the wizard.
    // Nothing happens while a playlist loads (page 5).
    return PopScope(
      canPop: _page == _firstPage,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || _page >= 5 || _page <= _firstPage) return;
        _goToPage(_page - 1);
      },
      child: Scaffold(
      backgroundColor: AppTheme.backgroundColor,
      resizeToAvoidBottomInset: true,
      body: PageView(
        controller: _pageController,
        physics: const NeverScrollableScrollPhysics(),
        // Only the page on show can take focus: all of them are built at
        // once, and the D-pad would otherwise slide off into a neighbouring
        // page (and the screen with it).
        children: <Widget>[
          // Placeholders keep page indices stable in playlist-only mode
          // without building (and autofocusing) the profile pages.
          if (addOnly) ...[
            const SizedBox.shrink(),
            const SizedBox.shrink(),
            const SizedBox.shrink(),
          ] else ...[
          _WelcomePage(
            onStart: () => _goToPage(1),
            onRestore: _restoreFromBackup,
            startFocusNode: _startFocusNode,
          ),
          _NamePage(
            nameCtrl: _nameCtrl,
            nameFocusNode: _nameFocusNode,
            selectedAvatar: _avatarEmoji,
            onAvatarSelected: (e) => setState(() => _avatarEmoji = e),
            selectedColor: _accentColor,
            onColorSelected: (c) => setState(() => _accentColor = c),
            onContinue: () {
              if (_nameCtrl.text.trim().isEmpty) return;
              _goToPage(2);
            },
            onBack: () => _goToPage(0),
          ),
          _PinPage(
            accentColor: _accentColor,
            firstDigitFocusNode: _pin1FocusNode,
            onBack: () => _goToPage(1),
            onSkip: () {
              setState(() => _pin = '');
              _goToPage(_credentialsPage);
            },
            onPinSet: (pin) {
              setState(() => _pin = pin);
              _goToPage(_credentialsPage);
            },
          ),
          ],
          const SizedBox.shrink(), // Keep the credentials page at its stable index.
          _CredentialsPage(
            accentColor: _accentColor,
            uniqueCodeCtrl: _xtreamCodeCtrl,
            codeFocusNode: _codeFocusNode,
            xtreamUserCtrl: _xtreamUserCtrl,
            xtreamPassCtrl: _xtreamPassCtrl,
            passVisible: _passVisible,
            onTogglePass: () => setState(() => _passVisible = !_passVisible),
            epgUrlCtrl: _epgUrlCtrl,
            errorMessage: _errorMessage,
            step: addOnly ? 1 : 2,
            totalSteps: totalSteps,
            onBack: addOnly
                ? (context.canPop() ? () => context.pop() : null)
                : () => _goToPage(2),
            onSubmit: _isLoading ? null : _submitSource,
          ),
          _LoadingPage(
            message:
                _progressMessage ?? AppLocalizations.of(context).wizardConnecting,
            accentColor: _accentColor,
            title: _restoring
                ? AppLocalizations.of(context).wizardLoadingRestoring
                : AppLocalizations.of(context).wizardLoadingSettingUp,
          ),
          _AllSetPage(
            headline: addOnly
                ? AppLocalizations.of(context).wizardAllSetAdded
                : _firstName(_nameCtrl.text).isEmpty
                    ? AppLocalizations.of(context).wizardAllSetHeadlineNoName
                    : AppLocalizations.of(context)
                        .wizardAllSetHeadline(_firstName(_nameCtrl.text)),
            accentColor: _accentColor,
            checkScale: _checkScale,
            sparkleAngle: _sparkleAngle,
          ),
        ].indexed
            .map((e) => ExcludeFocus(excluding: e.$1 != _page, child: e.$2))
            .toList(),
      ),
    ),
    );
  }
}

// ---------------------------------------------------------------------------
// Page 0 — Welcome
// ---------------------------------------------------------------------------

class _WelcomePage extends StatefulWidget {
  const _WelcomePage({
    required this.onStart,
    required this.onRestore,
    required this.startFocusNode,
  });
  final VoidCallback onStart;
  // Fresh install from an existing backup (reinstall, new Fire Stick) —
  // skips creating a profile and playlist by hand.
  final VoidCallback onRestore;
  final FocusNode startFocusNode;

  @override
  State<_WelcomePage> createState() => _WelcomePageState();
}

class _WelcomePageState extends State<_WelcomePage>
    with TickerProviderStateMixin {
  late final AnimationController _fadeCtrl;
  late final AnimationController _glowCtrl;
  late final Animation<double> _fade;
  late final Animation<double> _slide;
  late final Animation<double> _glowPulse;
  late final Animation<double> _btnScale;

  @override
  void initState() {
    super.initState();
    _glowCtrl = AnimationController(
      vsync: this,
      duration: motionDuration(const Duration(milliseconds: 2000)),
    );
    loopUnlessReduced(_glowCtrl, reverse: true);

    _fadeCtrl = AnimationController(
      vsync: this,
      duration: motionDuration(const Duration(milliseconds: 1200)),
    );

    _glowPulse = Tween(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(parent: _glowCtrl, curve: Curves.easeInOut),
    );
    _fade = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _fadeCtrl,
        curve: const Interval(0.0, 0.7, curve: Curves.easeOut),
      ),
    );
    _slide = Tween(begin: 30.0, end: 0.0).animate(
      CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOutCubic),
    );
    // A gentle ease-out rather than the old elastic overshoot: on TV the
    // button is the first thing focused, and a bouncing focus target reads
    // as jitter.
    _btnScale = Tween(begin: 0.92, end: 1.0).animate(
      CurvedAnimation(
        parent: _fadeCtrl,
        curve: const Interval(0.5, 1.0, curve: Curves.easeOutCubic),
      ),
    );

    _fadeCtrl.forward();
  }

  @override
  void dispose() {
    _fadeCtrl.dispose();
    _glowCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tv = PlatformHelper.isTV(context);
    // The mark shrinks on TV, where the whole page has to fit in about 540
    // logical pixels without scrolling.
    final logo = tv ? 112.0 : 150.0;
    // The strings carry a manual line break for the phone's narrow column; on
    // TV there is room for one line.
    String oneLine(String s) => tv ? s.replaceAll('\n', ' ') : s;
    final side = tv ? 40.0 : 32.0;

    return _WizardBackground(
      child: SafeArea(
        child: _WizardFocusGuard(
          child: Padding(
          padding: EdgeInsets.fromLTRB(side, tv ? 28 : 16, side, tv ? 28 : 20),
          child: Column(
            children: [
              Expanded(
                child: Center(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AnimatedBuilder(
                          animation: Listenable.merge([_fadeCtrl, _glowCtrl]),
                          builder: (_, child) => Opacity(
                            opacity: _fade.value,
                            child: SizedBox(
                              width: logo * 1.07,
                              height: logo * 1.07,
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  Container(
                                    width: logo * 1.07,
                                    height: logo * 1.07,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      gradient: RadialGradient(
                                        colors: [
                                          Color.fromRGBO(91, 79, 255,
                                              _glowPulse.value * 0.3),
                                          Color.fromRGBO(58, 46, 204,
                                              _glowPulse.value * 0.12),
                                          Colors.transparent,
                                        ],
                                      ),
                                    ),
                                  ),
                                  Container(
                                    width: logo * 0.73,
                                    height: logo * 0.73,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      gradient: RadialGradient(
                                        colors: [
                                          Color.fromRGBO(123, 111, 255,
                                              _glowPulse.value * 0.2),
                                          Colors.transparent,
                                        ],
                                      ),
                                    ),
                                  ),
                                  child!,
                                ],
                              ),
                            ),
                          ),
                          child: Image.asset(
                            'assets/images/logo_mark.png',
                            width: logo,
                            height: logo,
                          ),
                        ),
                        SizedBox(height: tv ? 24 : 40),
                        AnimatedBuilder(
                          animation: _fadeCtrl,
                          builder: (_, __) => Transform.translate(
                            offset: Offset(0, _slide.value),
                            child: Opacity(
                              opacity: _fade.value,
                              child: Column(
                                children: [
                                  ShaderMask(
                                    shaderCallback: (bounds) =>
                                        const LinearGradient(
                                      colors: [
                                        Colors.white,
                                        Color(0xFFC0B8FF)
                                      ],
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                    ).createShader(bounds),
                                    child: Text(
                                      oneLine(l10n.wizardWelcomeTitle),
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: tv ? 40 : 34,
                                        fontWeight: FontWeight.w800,
                                        height: 1.2,
                                      ),
                                    ),
                                  ),
                                  SizedBox(height: tv ? 10 : 16),
                                  Text(
                                    oneLine(l10n.wizardWelcomeSubtitle),
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: AppTheme.mutedTextColor,
                                      fontSize: tv ? 18 : 16,
                                      height: 1.5,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              SizedBox(height: tv ? 16 : 24),
              AnimatedBuilder(
                animation: _fadeCtrl,
                builder: (_, child) => Opacity(
                  opacity: _fade.value,
                  child: Transform.scale(scale: _btnScale.value, child: child),
                ),
                child: _GradientButton(
                  label: l10n.wizardGetStarted,
                  icon: Icons.arrow_forward,
                  accentColor: AppTheme.accentSwatches.first.color,
                  onTap: widget.onStart,
                  focusNode: widget.startFocusNode,
                  autofocus: true,
                ),
              ),
              const SizedBox(height: 8),
              FadeTransition(
                opacity: _fade,
                child: _TextAction(
                  icon: Icons.settings_backup_restore,
                  label: l10n.wizardRestoreFromBackup,
                  onTap: widget.onRestore,
                ),
              ),
              FadeTransition(
                opacity: _fade,
                child: Consumer(builder: (context, ref, _) {
                  final pref = ref.watch(languageProvider);
                  return _TextAction(
                    icon: Icons.language_rounded,
                    label: languageLabel(context, pref),
                    onTap: () => showLanguagePicker(context, ref),
                  );
                }),
              ),
            ],
          ),
        ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Page 1 — Name + Avatar
// ---------------------------------------------------------------------------

class _NamePage extends StatelessWidget {
  const _NamePage({
    required this.nameCtrl,
    required this.nameFocusNode,
    required this.selectedAvatar,
    required this.onAvatarSelected,
    required this.selectedColor,
    required this.onColorSelected,
    required this.onContinue,
    required this.onBack,
  });

  final TextEditingController nameCtrl;
  final FocusNode nameFocusNode;
  final String selectedAvatar;
  final ValueChanged<String> onAvatarSelected;
  final Color selectedColor;
  final ValueChanged<Color> onColorSelected;
  final VoidCallback onContinue;
  final VoidCallback onBack;

  static const _avatars = [
    '👨', '👩', '🧒', '👦', '👧', '🧑', '👴', '👵',
    '🎭', '🌟', '🎮', '🎬', '📺', '🎵', '🏠', '⚽',
    '🎸', '🐱', '🐶', '🦄',
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tv = PlatformHelper.isTV(context);
    final tile = tv ? 52.0 : 54.0;
    final swatch = tv ? 36.0 : 38.0;

    return _WizardFrame(
      accentColor: selectedColor,
      step: 0,
      totalSteps: 3,
      onBack: onBack,
      title: l10n.wizardNameTitle,
      subtitle: l10n.wizardPrivacyNote,
      footer: _GradientButton(
        label: l10n.wizardContinue,
        icon: Icons.arrow_forward,
        accentColor: selectedColor,
        onTap: onContinue,
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TvTextFieldGate(
            focusNode: nameFocusNode,
            borderRadius: _fieldRadius,
            builder: (context, fieldNode) => TextField(
              controller: nameCtrl,
              focusNode: fieldNode,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => onContinue(),
              autofillHints: null,
              style: _fieldTextStyle(tv),
              decoration: _fieldDecoration(
                accent: selectedColor,
                hint: l10n.wizardNameHint,
              ),
            ),
          ),
          SizedBox(height: tv ? 22 : 28),
          _SectionLabel(l10n.wizardPickAvatar),
          const SizedBox(height: 10),
          TvRowFocus(
            child: SizedBox(
            height: tile,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _avatars.length,
              itemBuilder: (context, i) {
                final emoji = _avatars[i];
                final selected = emoji == selectedAvatar;
                return Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: TvFocusable(
                    borderRadius: BorderRadius.circular(14),
                    ensureVisibleOnFocus: true,
                    onTap: () => onAvatarSelected(emoji),
                    child: AnimatedContainer(
                      duration:
                          motionDuration(const Duration(milliseconds: 200)),
                      width: tile,
                      height: tile,
                      decoration: BoxDecoration(
                        color: selected
                            ? selectedColor.withValues(alpha: 0.2)
                            : AppTheme.surfaceVariantColor,
                        border: Border.all(
                          color:
                              selected ? selectedColor : AppTheme.outlineColor,
                          width: selected ? 2 : 1,
                        ),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Center(
                        child:
                            Text(emoji, style: const TextStyle(fontSize: 26)),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          ),
          SizedBox(height: tv ? 22 : 28),
          _SectionLabel(l10n.wizardAccentColor),
          const SizedBox(height: 10),
          TvRowFocus(
            child: SizedBox(
            height: swatch + 6,
            child: Row(
              children: AppTheme.accentSwatches.map((s) {
                final sel = s.color == selectedColor;
                return Padding(
                  padding: const EdgeInsets.only(right: 14),
                  child: TvFocusable(
                    borderRadius: BorderRadius.circular(swatch / 2 + 3),
                    onTap: () => onColorSelected(s.color),
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: AnimatedContainer(
                        duration:
                            motionDuration(const Duration(milliseconds: 200)),
                        width: swatch,
                        height: swatch,
                        decoration: BoxDecoration(
                          color: s.color,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: sel ? Colors.white : Colors.transparent,
                            width: 3,
                          ),
                          boxShadow: sel
                              ? [
                                  BoxShadow(
                                    color: s.color.withValues(alpha: 0.6),
                                    blurRadius: 12,
                                    spreadRadius: 2,
                                  ),
                                ]
                              : null,
                        ),
                        child: sel
                            ? Icon(Icons.check,
                                color: AppTheme.onAccent(s.color), size: 18)
                            : null,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Page 2 — PIN (optional)
// ---------------------------------------------------------------------------

class _PinPage extends StatefulWidget {
  const _PinPage({
    required this.accentColor,
    required this.onSkip,
    required this.onPinSet,
    required this.onBack,
    required this.firstDigitFocusNode,
  });
  final Color accentColor;
  final VoidCallback onSkip;
  final ValueChanged<String> onPinSet;
  final VoidCallback onBack;
  final FocusNode firstDigitFocusNode;

  @override
  State<_PinPage> createState() => _PinPageState();
}

class _PinPageState extends State<_PinPage> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _valid => _controller.text.length >= kPinMinLength;

  void _submit() {
    if (!_valid) return;
    // Close the keyboard before the next page slides in.
    FocusManager.instance.primaryFocus?.unfocus();
    widget.onPinSet(_controller.text);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return _WizardFrame(
      accentColor: widget.accentColor,
      step: 1,
      totalSteps: 3,
      onBack: widget.onBack,
      title: l10n.wizardPinTitle,
      subtitle: l10n.wizardPinBody,
      footer: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _GradientButton(
            label: l10n.wizardSetPin,
            icon: Icons.lock,
            accentColor: widget.accentColor,
            onTap: _valid ? _submit : null,
          ),
          const SizedBox(height: 8),
          _TextAction(
            icon: Icons.skip_next_rounded,
            label: l10n.wizardSkipForNow,
            onTap: widget.onSkip,
          ),
        ],
      ),
      body: Theme(
        data: Theme.of(context).copyWith(
          colorScheme: Theme.of(context)
              .colorScheme
              .copyWith(primary: widget.accentColor),
        ),
        // System number keyboard, opened when the page is shown (the wizard
        // focuses this node).
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The box is empty until a digit is typed, so say what it is.
            _FieldLabel('${l10n.profilePinBadge} · ${l10n.profilePinDigitsHint}'),
            const SizedBox(height: 8),
            PinField(
              controller: _controller,
              focusNode: widget.firstDigitFocusNode,
              autofocus: false,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Page 4 — VedooTV playlist credentials
// ---------------------------------------------------------------------------

class _CredentialsPage extends StatelessWidget {
  const _CredentialsPage({
    required this.accentColor,
    required this.uniqueCodeCtrl,
    required this.codeFocusNode,
    required this.xtreamUserCtrl,
    required this.xtreamPassCtrl,
    required this.passVisible,
    required this.onTogglePass,
    required this.epgUrlCtrl,
    required this.errorMessage,
    required this.step,
    required this.totalSteps,
    required this.onBack,
    required this.onSubmit,
  });

  final Color accentColor;
  final TextEditingController uniqueCodeCtrl;
  final FocusNode codeFocusNode;
  final TextEditingController xtreamUserCtrl;
  final TextEditingController xtreamPassCtrl;
  final bool passVisible;
  final VoidCallback onTogglePass;
  final TextEditingController epgUrlCtrl;
  final String? errorMessage;
  final int step;
  final int totalSteps;
  final VoidCallback? onBack;
  final VoidCallback? onSubmit;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final rows = <List<Widget>>[
      [
        _WizardField(
          label: l10n.wizardUniqueCodeLabel,
          ctrl: uniqueCodeCtrl,
          hint: l10n.wizardUniqueCodeHint,
          accentColor: accentColor,
          focusNode: codeFocusNode,
        ),
      ],
      [
        _WizardField(
          label: l10n.wizardUsernameLabel,
          ctrl: xtreamUserCtrl,
          hint: l10n.wizardUsernameHint,
          accentColor: accentColor,
        ),
        _WizardField(
          label: l10n.wizardPasswordLabel,
          ctrl: xtreamPassCtrl,
          hint: l10n.wizardPasswordHint,
          obscure: !passVisible,
          accentColor: accentColor,
          suffix: IconButton(
            icon: Icon(
              passVisible ? Icons.visibility_off : Icons.visibility,
              color: AppTheme.mutedTextColor,
            ),
            tooltip: passVisible
                ? l10n.wizardPasswordHide
                : l10n.wizardPasswordShow,
            onPressed: onTogglePass,
          ),
        ),
      ],
      [
        _WizardField(
          label: l10n.wizardGuideUrlLabel,
          ctrl: epgUrlCtrl,
          hint: l10n.wizardGuideUrlHint,
          type: TextInputType.url,
          accentColor: accentColor,
        ),
      ],
    ];

    return _WizardFrame(
      accentColor: accentColor,
      step: step,
      totalSteps: totalSteps,
      onBack: onBack,
      title: l10n.wizardAddPlaylistTitle,
      subtitle: l10n.wizardCredsSubXtream,
      footer: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (errorMessage != null) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.error.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: theme.colorScheme.error.withValues(alpha: 0.4)),
              ),
              child: Row(
                children: [
                  Icon(Icons.error_outline,
                      color: theme.colorScheme.error, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      errorMessage!,
                      style: TextStyle(
                          color: theme.colorScheme.error, fontSize: 14),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
          _GradientButton(
            label: l10n.wizardLoadMyPlaylist,
            icon: Icons.download,
            accentColor: accentColor,
            onTap: onSubmit,
          ),
        ],
      ),
      body: _fieldRows(context, rows),
    );
  }
}

/// Lays out form [rows]: on TV, a row with several fields shares the width
/// (so the form fits the screen); on a phone every field gets its own row.
Widget _fieldRows(BuildContext context, List<List<Widget>> rows,
    {Map<int, List<int>> flex = const {}}) {
  final tv = PlatformHelper.isTV(context);
  final children = <Widget>[];
  for (final (r, row) in rows.indexed) {
    if (children.isNotEmpty) children.add(const SizedBox(height: 16));
    if (tv && row.length > 1) {
      final weights = flex[r];
      children.add(Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < row.length; i++) ...[
            if (i > 0) const SizedBox(width: 16),
            Expanded(flex: weights?[i] ?? 1, child: row[i]),
          ],
        ],
      ));
    } else {
      for (var i = 0; i < row.length; i++) {
        if (i > 0) children.add(const SizedBox(height: 16));
        children.add(row[i]);
      }
    }
  }
  return Column(crossAxisAlignment: CrossAxisAlignment.start, children: children);
}

class _WizardField extends StatelessWidget {
  const _WizardField({
    required this.label,
    required this.ctrl,
    required this.hint,
    required this.accentColor,
    this.type,
    this.obscure = false,
    this.suffix,
    this.focusNode,
  });

  final String label;
  final TextEditingController ctrl;
  final String hint;
  final Color accentColor;
  final TextInputType? type;
  final bool obscure;
  final Widget? suffix;
  // See TvFocusable.focusNode's doc — plain autofocus isn't reliable on a
  // wizard page that's built up front, long before it's actually shown.
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final tv = PlatformHelper.isTV(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _FieldLabel(label),
        const SizedBox(height: 6),
        TvTextFieldGate(
          focusNode: focusNode,
          borderRadius: _fieldRadius,
          builder: (context, fieldNode) => TextField(
            controller: ctrl,
            focusNode: fieldNode,
            keyboardType: type,
            obscureText: obscure,
            autocorrect: false,
            // No suggestion strip for addresses, logins or secrets.
            enableSuggestions: !obscure && type != TextInputType.url,
            // Not an autofill field. An empty hint list does NOT opt out: it
            // leaves the system to guess, and next to a password box it
            // guessed the server address was a password. null opts out.
            autofillHints: null,
            textInputAction: TextInputAction.next,
            style: _fieldTextStyle(tv),
            decoration: _fieldDecoration(
              accent: accentColor,
              hint: hint,
              suffix: suffix,
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Page 5 — Loading
// ---------------------------------------------------------------------------

class _LoadingPage extends StatefulWidget {
  const _LoadingPage({
    required this.message,
    required this.accentColor,
    this.title,
  });
  final String message;
  final Color accentColor;
  final String? title;

  @override
  State<_LoadingPage> createState() => _LoadingPageState();
}

class _LoadingPageState extends State<_LoadingPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseCtrl;
  late final Animation<double> _pulse;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: motionDuration(const Duration(milliseconds: 900)),
    );
    loopUnlessReduced(_pulseCtrl, reverse: true);
    _pulse = Tween(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tv = PlatformHelper.isTV(context);
    return _WizardBackground(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 90,
                height: 90,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    AnimatedBuilder(
                      animation: _pulse,
                      builder: (_, __) => Container(
                        width: 90,
                        height: 90,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            colors: [
                              widget.accentColor
                                  .withValues(alpha: _pulse.value * 0.25),
                              Colors.transparent,
                            ],
                          ),
                        ),
                      ),
                    ),
                    CircularProgressIndicator(
                      color: widget.accentColor,
                      strokeWidth: 3,
                    ),
                  ],
                ),
              ),
              SizedBox(height: tv ? 28 : 40),
              Text(
                widget.title ??
                    AppLocalizations.of(context).wizardLoadingSettingUp,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: tv ? 26 : 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              AnimatedBuilder(
                animation: _pulse,
                builder: (_, __) => Opacity(
                  opacity: 0.5 + _pulse.value * 0.5,
                  child: Text(
                    widget.message,
                    style: TextStyle(
                        color: AppTheme.mutedTextColor,
                        fontSize: tv ? 17 : 14),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Page 6 — All set!
// ---------------------------------------------------------------------------

class _AllSetPage extends StatelessWidget {
  const _AllSetPage({
    required this.headline,
    required this.accentColor,
    required this.checkScale,
    required this.sparkleAngle,
  });

  final String headline;
  final Color accentColor;
  final Animation<double> checkScale;
  final Animation<double> sparkleAngle;

  @override
  Widget build(BuildContext context) {
    final tv = PlatformHelper.isTV(context);
    return _WizardBackground(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 200,
                height: 200,
                child: AnimatedBuilder(
                  animation: Listenable.merge([checkScale, sparkleAngle]),
                  builder: (_, __) {
                    return Stack(
                      alignment: Alignment.center,
                      children: [
                        // Orbiting sparkle dots
                        ...List.generate(12, (i) {
                          final angle =
                              sparkleAngle.value + (i * 2 * pi / 12);
                          final radius = i % 2 == 0 ? 80.0 : 72.0;
                          final dx = cos(angle) * radius;
                          final dy = sin(angle) * radius;
                          final size = i % 3 == 0
                              ? 7.0
                              : i % 3 == 1
                                  ? 5.0
                                  : 4.0;
                          return Transform.translate(
                            offset: Offset(dx, dy),
                            child: Container(
                              width: size,
                              height: size,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: i % 3 == 0
                                    ? accentColor
                                    : i % 3 == 1
                                        ? _lighten(accentColor)
                                        : Colors.white
                                            .withValues(alpha: 0.5),
                              ),
                            ),
                          );
                        }),
                        // Outer glow
                        Container(
                          width: 130,
                          height: 130,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(
                              colors: [
                                accentColor.withValues(alpha: 0.3),
                                Colors.transparent,
                              ],
                            ),
                          ),
                        ),
                        // Checkmark
                        Transform.scale(
                          scale: checkScale.value,
                          child: Container(
                            width: 100,
                            height: 100,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: LinearGradient(
                                colors: [accentColor, _lighten(accentColor)],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: accentColor.withValues(alpha: 0.5),
                                  blurRadius: 30,
                                  offset: const Offset(0, 8),
                                ),
                              ],
                            ),
                            child: Icon(
                              Icons.check,
                              color: AppTheme.onAccent(accentColor),
                              size: 54,
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
              SizedBox(height: tv ? 28 : 44),
              ShaderMask(
                shaderCallback: (bounds) => const LinearGradient(
                  colors: [Colors.white, Color(0xFFC0B8FF)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ).createShader(bounds),
                child: Text(
                  headline,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: tv ? 36 : 30,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                AppLocalizations.of(context).wizardAllSetBody,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: AppTheme.mutedTextColor,
                    fontSize: tv ? 18 : 16,
                    height: 1.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

const _fieldRadius = BorderRadius.all(Radius.circular(12));

TextStyle _fieldTextStyle(bool tv) =>
    TextStyle(color: Colors.white, fontSize: tv ? 17 : 16);

/// One input look for every text field in the wizard (the name field used a
/// different radius, text size and padding from the rest).
InputDecoration _fieldDecoration({
  required Color accent,
  required String hint,
  Widget? suffix,
}) {
  OutlineInputBorder border(Color c, [double w = 1]) => OutlineInputBorder(
        borderRadius: _fieldRadius,
        borderSide: BorderSide(color: c, width: w),
      );
  return InputDecoration(
    hintText: hint,
    hintStyle: const TextStyle(color: AppTheme.mutedTextColor),
    filled: true,
    fillColor: AppTheme.surfaceVariantColor,
    border: border(AppTheme.fieldBorderColor),
    enabledBorder: border(AppTheme.fieldBorderColor),
    focusedBorder: border(accent, 2),
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    suffixIcon: suffix,
  );
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: TextStyle(
          color: Colors.white70,
          fontSize: PlatformHelper.isTV(context) ? 14 : 13,
          fontWeight: FontWeight.w600,
        ),
      );
}

/// A small heading above a group of controls (avatars, accent colours).
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: TextStyle(
          color: Colors.white70,
          fontSize: PlatformHelper.isTV(context) ? 15 : 14,
          fontWeight: FontWeight.w600,
        ),
      );
}

/// Keeps the D-pad on the page. Every wizard page is built at once, and a
/// scrolling row builds a few items beyond its edge; Flutter's directional
/// search will happily jump Right from a full-width button to one of those
/// unseen items (or to a control on another row). A sideways move that leaves
/// the row, or this page's own column, is undone, so Left/Right on a lone
/// control simply stay put.
class _WizardFocusGuard extends StatelessWidget {
  const _WizardFocusGuard({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Actions(
        actions: {
          DirectionalFocusIntent: CallbackAction<DirectionalFocusIntent>(
            onInvoke: (intent) {
              final before = FocusManager.instance.primaryFocus;
              final moved = focusInDirectionSafely(before, intent.direction);
              final sideways = intent.direction == TraversalDirection.left ||
                  intent.direction == TraversalDirection.right;
              final box = context.findRenderObject();
              final after = FocusManager.instance.primaryFocus;
              if (moved && sideways && box is RenderBox && after != null) {
                final area = box.localToGlobal(Offset.zero) & box.size;
                final from = before?.rect;
                // Left/Right stay on the same row (a little slack for a
                // scaled button) and inside the page's column.
                final sameRow = from != null &&
                    after.rect.center.dy >= from.top - 6 &&
                    after.rect.center.dy <= from.bottom + 6;
                if (!sameRow || !area.inflate(4).contains(after.rect.center)) {
                  before?.requestFocus();
                }
              }
              return null;
            },
          ),
        },
        child: child,
      );
}

class _WizardBackground extends StatelessWidget {
  const _WizardBackground({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Every page is laid out for a phone-width column; on a TV the column is
    // capped and centred so nothing stretches across the screen. Height is
    // left to each page: a TV's usable height (about 540 logical pixels) is
    // shorter than a phone's, so pages fit it by design and scroll their
    // middle rather than trusting a fixed size.
    Widget wrap(Widget page) {
      if (!PlatformHelper.isTV(context)) return page;
      return Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: page,
        ),
      );
    }

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppTheme.backgroundColor, AppTheme.surfaceColor],
        ),
      ),
      child: wrap(child),
    );
  }
}

/// The frame every page after the welcome shares, so the header, title,
/// subtitle and button sit in exactly the same place from step to step:
/// Back arrow + step dots, a title and subtitle, the page's own [body]
/// (scrolls if it must) and a pinned [footer].
class _WizardFrame extends StatelessWidget {
  const _WizardFrame({
    required this.accentColor,
    required this.step,
    required this.totalSteps,
    required this.title,
    required this.body,
    this.subtitle,
    this.footer,
    this.onBack,
  });

  final Color accentColor;
  final int step;
  final int totalSteps;
  final String title;
  final String? subtitle;
  final Widget body;
  final Widget? footer;
  // Null on the first page shown, where there is nowhere to go back to.
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: TvTextInput.showing,
        builder: (context, keyboard, _) => _build(context, keyboard),
      );

  Widget _build(BuildContext context, bool keyboard) {
    final tv = PlatformHelper.isTV(context);
    final side = tv ? 40.0 : 24.0;
    // With the TV keyboard up the page has about 300 logical pixels: the
    // subtitle and the pinned button give way to the form (the keyboard's own
    // action key moves on), instead of the button riding up over the field.
    final compact = tv && keyboard;
    return _WizardBackground(
      child: SafeArea(
        child: _WizardFocusGuard(
          child: Padding(
          padding: EdgeInsets.fromLTRB(side, tv ? 24 : 8, side, tv ? 24 : 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // A fixed-height header, with or without a Back arrow, so the
              // title never jumps between steps.
              SizedBox(
                height: 44,
                child: Row(
                  children: [
                    if (onBack != null) ...[
                      _BackButton(onTap: onBack!),
                      const SizedBox(width: 12),
                    ],
                    _StepIndicator(
                        current: step,
                        total: totalSteps,
                        accentColor: accentColor),
                  ],
                ),
              ),
              SizedBox(height: tv ? 14 : 20),
              Text(
                // Titles carry a manual line break for the phone's narrow
                // column; a TV has the width for one line.
                tv ? title.replaceAll('\n', ' ') : title,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: tv ? 30 : 28,
                  fontWeight: FontWeight.w800,
                  height: 1.2,
                ),
              ),
              // Hidden, never removed, while the keyboard is up: taking a child
              // out of this column would shift the form's place in the tree,
              // rebuild its field and close the keyboard.
              if (subtitle != null)
                Offstage(
                  offstage: compact,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      subtitle!,
                      style: TextStyle(
                        color: AppTheme.mutedTextColor,
                        fontSize: tv ? 16 : 14,
                        height: 1.4,
                      ),
                    ),
                  ),
                ),
              SizedBox(height: compact ? 12 : (tv ? 18 : 24)),
              Expanded(
                // Clipped to its own area: a form scrolled up for the keyboard
                // must not draw over the title above it.
                child: SingleChildScrollView(child: body),
              ),
              if (footer != null)
                Offstage(
                  offstage: compact,
                  child: ExcludeFocus(
                    excluding: compact,
                    child: Padding(
                      padding: EdgeInsets.only(top: tv ? 14 : 16),
                      child: footer!,
                    ),
                  ),
                ),
            ],
          ),
        ),
        ),
      ),
    );
  }
}

/// The round Back arrow in every page's header; a focus stop on TV (Up from
/// the first control) and a tap target on phones.
class _BackButton extends StatelessWidget {
  const _BackButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: AppLocalizations.of(context).commonBack,
        excludeSemantics: true,
        child: TvFocusable(
          borderRadius: BorderRadius.circular(22),
          onTap: onTap,
          child: const SizedBox(
            width: 44,
            height: 44,
            child: Icon(Icons.arrow_back_rounded,
                color: Colors.white70, size: 24),
          ),
        ),
      );
}

/// A quiet, centred text button (Skip, Restore, Language) that takes the same
/// focus pill as every other control.
class _TextAction extends StatelessWidget {
  const _TextAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Center(
        child: TvFocusable(
          borderRadius: BorderRadius.circular(22),
          onTap: onTap,
          child: SizedBox(
            height: 44,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, color: AppTheme.mutedTextColor, size: 20),
                  const SizedBox(width: 10),
                  Text(
                    label,
                    style: const TextStyle(
                        color: AppTheme.mutedTextColor, fontSize: 15),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
}

class _StepIndicator extends StatelessWidget {
  const _StepIndicator({
    required this.current,
    required this.total,
    required this.accentColor,
  });
  final int current;
  final int total;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: List.generate(total, (i) {
        final active = i == current;
        final done = i < current;
        return AnimatedContainer(
          duration: motionDuration(const Duration(milliseconds: 300)),
          margin: const EdgeInsets.only(right: 6),
          width: active ? 28 : 8,
          height: 8,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            color: active
                ? accentColor
                : done
                    ? _lighten(accentColor).withValues(alpha: 0.6)
                    : AppTheme.outlineColor,
          ),
        );
      }),
    );
  }
}

/// The wizard's main action. Its fill is the accent, so the usual accent pill
/// would vanish on it; focused on TV it lightens and grows a touch instead.
class _GradientButton extends StatefulWidget {
  const _GradientButton({
    required this.label,
    required this.icon,
    required this.accentColor,
    required this.onTap,
    this.focusNode,
    this.autofocus = false,
  });

  final String label;
  final IconData icon;
  final Color accentColor;
  final VoidCallback? onTap;
  final FocusNode? focusNode;
  final bool autofocus;

  @override
  State<_GradientButton> createState() => _GradientButtonState();
}

class _GradientButtonState extends State<_GradientButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final tv = PlatformHelper.isTV(context);
    final lit = _focused && tv;
    final accent = widget.accentColor;
    Color glow(Color c) => lit ? Color.lerp(c, Colors.white, 0.28)! : c;
    // A disabled button takes no focus, so the D-pad skips it rather than
    // stopping on something that does nothing.
    return ExcludeFocus(
      excluding: !enabled,
      child: TvFocusable(
        showFocusRing: false,
        autofocus: widget.autofocus && enabled,
        focusNode: widget.focusNode,
        onFocusChange: (f) => setState(() => _focused = f),
        onTap: widget.onTap ?? () {},
        borderRadius: BorderRadius.circular(14),
        child: AnimatedScale(
          scale: lit ? 1.03 : 1.0,
          duration: motionDuration(TvFocusStyle.duration),
          curve: TvFocusStyle.curve,
          child: AnimatedOpacity(
            duration: motionDuration(const Duration(milliseconds: 200)),
            opacity: enabled ? 1.0 : 0.45,
            child: Container(
              height: tv ? 54 : 56,
              decoration: BoxDecoration(
                gradient: enabled
                    ? LinearGradient(
                        colors: [glow(accent), glow(_lighten(accent))],
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                      )
                    : null,
                color: enabled ? null : AppTheme.surfaceVariantColor,
                borderRadius: BorderRadius.circular(14),
                boxShadow: enabled
                    ? [
                        BoxShadow(
                          color: accent.withValues(alpha: lit ? 0.6 : 0.4),
                          blurRadius: lit ? 22 : 16,
                          offset: const Offset(0, 6),
                        ),
                      ]
                    : null,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    widget.label,
                    style: TextStyle(
                      color: enabled
                          ? AppTheme.onAccent(accent)
                          : Colors.white,
                      fontSize: tv ? 17 : 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Icon(widget.icon,
                      color: enabled
                          ? AppTheme.onAccent(accent)
                          : Colors.white,
                      size: 20),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
