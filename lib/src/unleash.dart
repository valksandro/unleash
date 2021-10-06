import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:unleash/src/features.dart';
import 'package:unleash/src/strategies.dart';
import 'package:unleash/src/strategy.dart';
import 'package:unleash/src/toggle_backup.dart';
import 'package:unleash/src/unleash_settings.dart';

typedef UpdateCallback = void Function();

class Unleash {
  Unleash._internal(this.settings, this._onUpdate);

  final UnleashSettings settings;
  final UpdateCallback _onUpdate;
  final List<ActivationStrategy> _activationStrategies = [DefaultStrategy()];

  /// Collection of all available feature toggles
  Features _features;

  /// The client which is used by unleash to make the requests

  /// This timer is responsible for starting a new request
  /// every time the given [UnleashSettings.pollingInterval] expired.
  Timer _togglePollingTimer;

  ToggleBackupRepository _backupRepository;

  /// Initializes an [Unleash] instance, registers it at the backend and
  /// starts to load the feature toggles.
  /// [settings] are used to specify the backend and various other settings.
  /// A [client] can be used for example to further configure http headers
  /// according to your needs.
  static Future<Unleash> init(
    UnleashSettings settings, {
    http.Client client,
    ReadBackup readBackup,
    WriteBackup writeBackup,
    UpdateCallback onUpdate,
  }) async {
    final unleash = Unleash._internal(
      settings,
      onUpdate
    );
    if (writeBackup != null && readBackup != null) {
      unleash._backupRepository =
          ToggleBackupRepository(readBackup, writeBackup);
    }

    unleash._activationStrategies.addAll(settings.strategies ?? List.empty());

    await unleash._loadToggles();
    unleash._setTogglePollingTimer();
    return unleash;
  }

  bool isEnabled(String toggleName, {bool defaultValue = false}) {
    final defaultToggle = FeatureToggle(
      name: toggleName,
      strategies: null,
      description: null,
      enabled: defaultValue,
      strategy: null,
    );

    final featureToggle = _features?.features?.firstWhere(
      (toggle) => toggle.name == toggleName,
      orElse: () => defaultToggle,
    );

    final toggle = featureToggle ?? defaultToggle;
    final isEnabled = toggle.enabled ?? defaultValue;

    if (!isEnabled) {
      return false;
    }

    final strategies = toggle.strategies ?? List<Strategy>.empty();

    if (strategies.isEmpty) {
      return isEnabled;
    }

    for (final strategy in strategies) {
      final foundStrategy = _activationStrategies.firstWhere(
        (activationStrategy) => activationStrategy.name == strategy.name,
        orElse: () => UnknownStrategy(),
      );

      final parameters = strategy.parameters ?? <String, dynamic>{};

      if (foundStrategy.isEnabled(parameters)) {
        return true;
      }
    }

    return false;
  }

  /// Cancels all periodic actions of this Unleash instance
  void dispose() {
    _togglePollingTimer?.cancel();
  }

  Future<void> _loadToggles() async {
    try {
      final response = await http.get(
        settings.featureUrl,
        headers: settings.toHeaders(),
      );
      final stringResponse = utf8.decode(response.bodyBytes);

      await _backupRepository?.write(settings, stringResponse);

      _features = Features.fromJson(
          json.decode(stringResponse) as Map<String, dynamic>);

      _onUpdate?.call();
    } catch (_) {
      // TODO: Should there be some other form of error handling?
      _features = await _backupRepository?.load(settings);
    }
  }

  void _setTogglePollingTimer() {
    // disable polling if no pollingInterval is given
    if (settings.pollingInterval == null) {
      return;
    }
    _togglePollingTimer = Timer.periodic(settings.pollingInterval, (timer) {
      _loadToggles();
    });
  }
}
