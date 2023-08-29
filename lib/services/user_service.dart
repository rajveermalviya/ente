import 'dart:async';
import "dart:convert";
import "dart:math";

import 'package:bip39/bip39.dart' as bip39;
import 'package:dio/dio.dart';
import 'package:ente_auth/core/configuration.dart';
import 'package:ente_auth/core/constants.dart';
import 'package:ente_auth/core/errors.dart';
import 'package:ente_auth/core/event_bus.dart';
import 'package:ente_auth/core/network.dart';
import 'package:ente_auth/events/user_details_changed_event.dart';
import 'package:ente_auth/l10n/l10n.dart';
import 'package:ente_auth/models/api/user/srp.dart';
import 'package:ente_auth/models/delete_account.dart';
import 'package:ente_auth/models/key_attributes.dart';
import 'package:ente_auth/models/key_gen_result.dart';
import 'package:ente_auth/models/sessions.dart';
import 'package:ente_auth/models/set_keys_request.dart';
import 'package:ente_auth/models/set_recovery_key_request.dart';
import 'package:ente_auth/models/user_details.dart';
import 'package:ente_auth/ui/account/login_page.dart';
import 'package:ente_auth/ui/account/ott_verification_page.dart';
import 'package:ente_auth/ui/account/password_entry_page.dart';
import 'package:ente_auth/ui/account/password_reentry_page.dart';
import 'package:ente_auth/ui/account/recovery_page.dart';
import 'package:ente_auth/ui/components/buttons/button_widget.dart';
import 'package:ente_auth/ui/home_page.dart';
import 'package:ente_auth/ui/two_factor_authentication_page.dart';
import 'package:ente_auth/ui/two_factor_recovery_page.dart';
import 'package:ente_auth/utils/crypto_util.dart';
import 'package:ente_auth/utils/dialog_util.dart';
import 'package:ente_auth/utils/email_util.dart';
import 'package:ente_auth/utils/toast_util.dart';
import "package:flutter/foundation.dart";
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import "package:pointycastle/export.dart";
import "package:pointycastle/srp/srp6_client.dart";
import "package:pointycastle/srp/srp6_standard_groups.dart";
import "package:pointycastle/srp/srp6_util.dart";
import "package:pointycastle/srp/srp6_verifier_generator.dart";
import 'package:shared_preferences/shared_preferences.dart';
import "package:uuid/uuid.dart";

class UserService {
  static const keyHasEnabledTwoFactor = "has_enabled_two_factor";
  static const keyUserDetails = "user_details";
  static const kCanDisableEmailMFA = "can_disable_email_mfa";
  static const kIsEmailMFAEnabled = "is_email_mfa_enabled";
  final  SRP6GroupParameters kDefaultSrpGroup = SRP6StandardGroups.rfc5054_4096;
  final _dio = Network.instance.getDio();
  final _enteDio = Network.instance.enteDio;
  final _logger = Logger((UserService).toString());
  final _config = Configuration.instance;
  late SharedPreferences _preferences;

  late ValueNotifier<String?> emailValueNotifier;

  UserService._privateConstructor();

  static final UserService instance = UserService._privateConstructor();

  Future<void> init() async {
    emailValueNotifier =
        ValueNotifier<String?>(Configuration.instance.getEmail());
    _preferences = await SharedPreferences.getInstance();
  }

  Future<void> sendOtt(
      BuildContext context,
      String email, {
        bool isChangeEmail = false,
        bool isCreateAccountScreen = false,
        bool isResetPasswordScreen = false,
      }) async {
    final dialog = createProgressDialog(context, context.l10n.pleaseWait);
    await dialog.show();
    try {
      final response = await _dio.post(
        _config.getHttpEndpoint() + "/users/ott",
        data: {"email": email, "purpose": isChangeEmail ? "change" : ""},
      );
      await dialog.hide();
      if (response.statusCode == 200) {
        unawaited(
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (BuildContext context) {
                return OTTVerificationPage(
                  email,
                  isChangeEmail: isChangeEmail,
                  isCreateAccountScreen: isCreateAccountScreen,
                  isResetPasswordScreen: isResetPasswordScreen,
                );
              },
            ),
          ),
        );
        return;
      }
      unawaited(showGenericErrorDialog(context: context));
    } on DioError catch (e) {
      await dialog.hide();
      _logger.info(e);
      if (e.response != null && e.response!.statusCode == 403) {
        unawaited(
          showErrorDialog(
            context,
            context.l10n.oops,
            context.l10n.thisEmailIsAlreadyInUse,
          ),
        );
      } else {
        unawaited(showGenericErrorDialog(context: context));
      }
    } catch (e) {
      await dialog.hide();
      _logger.severe(e);
      unawaited(showGenericErrorDialog(context: context));
    }
  }

  Future<void> sendFeedback(
      BuildContext context,
      String feedback, {
        String type = "SubCancellation",
      }) async {
    await _dio.post(
      _config.getHttpEndpoint() + "/anonymous/feedback",
      data: {"feedback": feedback, "type": "type"},
    );
  }


  Future<UserDetails> getUserDetailsV2({
    bool memoryCount = false,
    bool shouldCache = true,
  }) async {
    try {
      final response = await _enteDio.get(
        "/users/details/v2",
        queryParameters: {
          "memoryCount": memoryCount,
        },
      );
      final userDetails = UserDetails.fromMap(response.data);
      if (shouldCache) {
        if(userDetails.profileData != null) {
          _preferences.setBool(kIsEmailMFAEnabled, userDetails.profileData!.isEmailMFAEnabled);
          _preferences.setBool(kCanDisableEmailMFA, userDetails.profileData!.canDisableEmailMFA);
        }
        // handle email change from different client
        if (userDetails.email != _config.getEmail()) {
          setEmail(userDetails.email);
        }
      }
      return userDetails;
    } catch(e) {
      _logger.warning("Failed to fetch", e);
      rethrow;
    }
  }

  Future<Sessions> getActiveSessions() async {
    try {
      final response = await _enteDio.get("/users/sessions");
      return Sessions.fromMap(response.data);
    } on DioError catch (e) {
      _logger.info(e);
      rethrow;
    }
  }

  Future<void> terminateSession(String token) async {
    try {
      await _enteDio.delete(
        "/users/session",
        queryParameters: {
          "token": token,
        },
      );
    } on DioError catch (e) {
      _logger.info(e);
      rethrow;
    }
  }

  Future<void> leaveFamilyPlan() async {
    try {
      await _enteDio.delete("/family/leave");
    } on DioError catch (e) {
      _logger.warning('failed to leave family plan', e);
      rethrow;
    }
  }

  Future<void> logout(BuildContext context) async {
    try {
      final response = await _enteDio.post("/users/logout");
      if (response.statusCode == 200) {
        await Configuration.instance.logout();
        Navigator.of(context).popUntil((route) => route.isFirst);
      } else {
        throw Exception("Log out action failed");
      }
    } catch (e) {
      _logger.severe(e);
      //This future is for waiting for the dialog from which logout() is called
      //to close and only then to show the error dialog.
      Future.delayed(
        const Duration(milliseconds: 150),
            () => showGenericErrorDialog(context: context),
      );
      rethrow;
    }
  }

  Future<DeleteChallengeResponse?> getDeleteChallenge(
      BuildContext context,
      ) async {
    try {
      final response = await _enteDio.get("/users/delete-challenge");
      if (response.statusCode == 200) {
        return DeleteChallengeResponse(
          allowDelete: response.data["allowDelete"] as bool,
          encryptedChallenge: response.data["encryptedChallenge"],
        );
      } else {
        throw Exception("delete action failed");
      }
    } catch (e) {
      _logger.severe(e);
      await showGenericErrorDialog(context: context);
      return null;
    }
  }

  Future<void> deleteAccount(
      BuildContext context,
      String challengeResponse,) async {
    try {
      final response = await _enteDio.delete(
        "/users/delete",
        data: {
          "challenge": challengeResponse,
        },
      );
      if (response.statusCode == 200) {
        // clear data
        await Configuration.instance.logout();
      } else {
        throw Exception("delete action failed");
      }
    } catch (e) {
      _logger.severe(e);
      rethrow;
    }
  }

  Future<void> verifyEmail(BuildContext context, String ott, {bool
  isResettingPasswordScreen = false,})
  async {
    final dialog = createProgressDialog(context, context.l10n.pleaseWait);
    await dialog.show();
    try {
      final response = await _dio.post(
        _config.getHttpEndpoint() + "/users/verify-email",
        data: {
          "email": _config.getEmail(),
          "ott": ott,
        },
      );
      await dialog.hide();
      if (response.statusCode == 200) {
        Widget page;
        final String twoFASessionID = response.data["twoFactorSessionID"];
        if (twoFASessionID.isNotEmpty) {
          page = TwoFactorAuthenticationPage(twoFASessionID);
        } else {
          await _saveConfiguration(response);
          if (Configuration.instance.getEncryptedToken() != null) {
            if(isResettingPasswordScreen) {
              page = const RecoveryPage();
            } else {
              page = const PasswordReentryPage();
            }

          } else {
            page = const PasswordEntryPage(mode: PasswordEntryMode.set,);
          }
        }
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (BuildContext context) {
              return page;
            },
          ),
              (route) => route.isFirst,
        );
      } else {
        // should never reach here
        throw Exception("unexpected response during email verification");
      }
    } on DioError catch (e) {
      _logger.info(e);
      await dialog.hide();
      if (e.response != null && e.response!.statusCode == 410) {
        await showErrorDialog(
          context,
          context.l10n.oops,
          context.l10n.yourVerificationCodeHasExpired,
        );
        Navigator.of(context).pop();
      } else {
        showErrorDialog(
          context,
          context.l10n.incorrectCode,
          context.l10n.sorryTheCodeYouveEnteredIsIncorrect,
        );
      }
    } catch (e) {
      await dialog.hide();
      _logger.severe(e);
      showErrorDialog(
        context,
        context.l10n.oops,
        context.l10n.verificationFailedPleaseTryAgain,
      );
    }
  }

  Future<void> setEmail(String email) async {
    await _config.setEmail(email);
    emailValueNotifier.value = email;
  }

  Future<void> changeEmail(
      BuildContext context,
      String email,
      String ott,
      ) async {
    final dialog = createProgressDialog(context, context.l10n.pleaseWait);
    await dialog.show();
    try {
      final response = await _enteDio.post(
        "/users/change-email",
        data: {
          "email": email,
          "ott": ott,
        },
      );
      await dialog.hide();
      if (response.statusCode == 200) {
        showShortToast(context, context.l10n.emailChangedTo(email));
        await setEmail(email);
        Navigator.of(context).popUntil((route) => route.isFirst);
        Bus.instance.fire(UserDetailsChangedEvent());
        return;
      }
      showErrorDialog(
        context,
        context.l10n.oops,
        context.l10n.verificationFailedPleaseTryAgain,
      );
    } on DioError catch (e) {
      await dialog.hide();
      if (e.response != null && e.response!.statusCode == 403) {
        showErrorDialog(
          context,
          context.l10n.oops,
          context.l10n.thisEmailIsAlreadyInUse,
        );
      } else {
        showErrorDialog(
          context,
          context.l10n.incorrectCode,
          context.l10n.authenticationFailedPleaseTryAgain,
        );
      }
    } catch (e) {
      await dialog.hide();
      _logger.severe(e);
      showErrorDialog(
        context,
        context.l10n.oops,
        context.l10n.verificationFailedPleaseTryAgain,
      );
    }
  }

  Future<void> setAttributes(KeyGenResult result) async {
    try {
      await registerOrUpdateSrp(result.loginKey);
      await _enteDio.put(
        "/users/attributes",
        data: {
          "keyAttributes": result.keyAttributes.toMap(),
        },
      );
      await _config.setKey(result.privateKeyAttributes.key);
      await _config.setSecretKey(result.privateKeyAttributes.secretKey);
      await _config.setKeyAttributes(result.keyAttributes);
    } catch (e) {
      _logger.severe(e);
      rethrow;
    }
  }

  Future<SrpAttributes> getSrpAttributes(String email) async {
    try {
      final response = await _dio.get(
        _config.getHttpEndpoint() + "/users/srp/attributes",
        queryParameters: {
          "email": email,
        },
      );
      if (response.statusCode == 200) {
        return SrpAttributes.fromMap(response.data);
      } else {
        throw Exception("get-srp-attributes action failed");
      }
    } on DioError catch (e) {
      if (e.response != null && e.response!.statusCode == 404) {
        throw SrpSetupNotCompleteError();
      }
      rethrow;
    } catch (e) {
      rethrow;
    }
  }

  Future<void> registerOrUpdateSrp(
      Uint8List loginKey, {
        SetKeysRequest? setKeysRequest,
      }) async {
    try {
      final String username = const Uuid().v4().toString();
      final SecureRandom random = _getSecureRandom();
      final Uint8List identity = Uint8List.fromList(utf8.encode(username));
      final Uint8List password = loginKey;
      final Uint8List salt = random.nextBytes(16);
      final gen = SRP6VerifierGenerator(
        group: kDefaultSrpGroup,
        digest: Digest('SHA-256'),
      );
      final v = gen.generateVerifier(salt, identity, password);

      final client = SRP6Client(
        group: kDefaultSrpGroup,
        digest: Digest('SHA-256'),
        random: random,
      );

      final A = client.generateClientCredentials(salt, identity, password);
      final request = SetupSRPRequest(
        srpUserID: username,
        srpSalt: base64Encode(salt),
        srpVerifier: base64Encode(SRP6Util.encodeBigInt(v)),
        srpA: base64Encode(SRP6Util.encodeBigInt(A!)),
        isUpdate: false,
      );
      final response = await _enteDio.post(
        "/users/srp/setup",
        data: request.toMap(),
      );
      if (response.statusCode == 200) {
        final SetupSRPResponse setupSRPResponse =
        SetupSRPResponse.fromJson(response.data);
        final serverB =
        SRP6Util.decodeBigInt(base64Decode(setupSRPResponse.srpB));
        // ignore: need to calculate secret to get M1, unused_local_variable
        final clientS = client.calculateSecret(serverB);
        final clientM = client.calculateClientEvidenceMessage();
        late Response srpCompleteResponse;
        if(setKeysRequest == null) {
          srpCompleteResponse = await _enteDio.post(
            "/users/srp/complete",
            data: {
              'setupID': setupSRPResponse.setupID,
              'srpM1': base64Encode(SRP6Util.encodeBigInt(clientM!)),
            },
          );
        } else {
          srpCompleteResponse = await _enteDio.post(
            "/users/srp/update",
            data: {
              'setupID': setupSRPResponse.setupID,
              'srpM1': base64Encode(SRP6Util.encodeBigInt(clientM!)),
              'updatedKeyAttr': setKeysRequest.toMap(),
            },
          );
        }
      } else {
        throw Exception("register-srp action failed");
      }
    } catch (e,s) {
      _logger.severe("failed to register srp" ,e,s);
      rethrow;
    }
  }

  SecureRandom _getSecureRandom() {
    final List<int> seeds = [];
    final random = Random.secure();
    for (int i = 0; i < 32; i++) {
      seeds.add(random.nextInt(255));
    }
    final secureRandom = FortunaRandom();
    secureRandom.seed(KeyParameter(Uint8List.fromList(seeds)));
    return secureRandom;
  }

  Future<void> verifyEmailViaPassword(
      BuildContext context,
      SrpAttributes srpAttributes,
      String userPassword,
      ) async {
    final dialog = createProgressDialog(
      context,
      context.l10n.pleaseWait,
      isDismissible: true,
    );
    await dialog.show();
    late Uint8List keyEncryptionKey;
    try {
      keyEncryptionKey = await CryptoUtil.deriveKey(
        utf8.encode(userPassword) as Uint8List,
        CryptoUtil.base642bin(srpAttributes.kekSalt),
        srpAttributes.memLimit,
        srpAttributes.opsLimit,
      );
      final loginKey = await CryptoUtil.deriveLoginKey(keyEncryptionKey);
      final Uint8List identity = Uint8List.fromList(
        utf8.encode(srpAttributes.srpUserID),
      );
      final Uint8List salt = base64Decode(srpAttributes.srpSalt);
      final Uint8List password = loginKey;
      final SecureRandom random = _getSecureRandom();

      final client = SRP6Client(
        group: kDefaultSrpGroup,
        digest: Digest('SHA-256'),
        random: random,
      );

      final A = client.generateClientCredentials(salt, identity, password);
      final createSessionResponse = await _dio.post(
        _config.getHttpEndpoint() + "/users/srp/create-session",
        data: {
          "srpUserID": srpAttributes.srpUserID,
          "srpA": base64Encode(SRP6Util.encodeBigInt(A!)),
        },
      );
      final String sessionID = createSessionResponse.data["sessionID"];
      final String srpB = createSessionResponse.data["srpB"];

      final serverB = SRP6Util.decodeBigInt(base64Decode(srpB));
      // ignore: need to calculate secret to get M1, unused_local_variable
      final clientS = client.calculateSecret(serverB);
      final clientM = client.calculateClientEvidenceMessage();
      final response = await _dio.post(
        _config.getHttpEndpoint() + "/users/srp/verify-session",
        data: {
          "sessionID": sessionID,
          "srpUserID": srpAttributes.srpUserID,
          "srpM1": base64Encode(SRP6Util.encodeBigInt(clientM!)),
        },
      );
      if (response.statusCode == 200) {
        Widget page;
        final String twoFASessionID = response.data["twoFactorSessionID"];
        Configuration.instance.setVolatilePassword(userPassword);
        if (twoFASessionID.isNotEmpty) {
          page = TwoFactorAuthenticationPage(twoFASessionID);
        } else {
          await _saveConfiguration(response);
          if (Configuration.instance.getEncryptedToken() != null) {
            await Configuration.instance.decryptSecretsAndGetKeyEncKey(
              userPassword,
              Configuration.instance.getKeyAttributes()!,
              keyEncryptionKey: keyEncryptionKey,
            );
            page = const HomePage();
          } else {
            throw Exception("unexpected response during email verification");
          }
        }
        await dialog.hide();
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (BuildContext context) {
              return page;
            },
          ),
              (route) => route.isFirst,
        );
      } else {
        // should never reach here
        throw Exception("unexpected response during email verification");
      }
    } on DioError catch (e, s) {
      await dialog.hide();
      if (e.response != null && e.response!.statusCode == 401) {
        final dialogChoice = await showChoiceDialog(
          context,
          title: context.l10n.incorrectPasswordTitle,
          body: context.l10n.pleaseTryAgain,
          firstButtonLabel: context.l10n.contactSupport,
          secondButtonLabel: context.l10n.ok,
        );
        if (dialogChoice!.action == ButtonAction.first) {
          await sendLogs(
            context,
            context.l10n.contactSupport,
            "support@ente.io",
            postShare: () {},
          );
        }
      } else {
        _logger.fine('failed to verify password', e, s);
        await showErrorDialog(
          context,
          context.l10n.oops,
          context.l10n.verificationFailedPleaseTryAgain,
        );
      }
    } catch (e, s) {
      _logger.fine('failed to verify password', e, s);
      await dialog.hide();
      await showErrorDialog(
        context,
        context.l10n.oops,
        context.l10n.verificationFailedPleaseTryAgain,
      );
    }
  }

  Future<void> updateKeyAttributes(KeyAttributes keyAttributes, Uint8List
  loginKey,)
  async {
    try {
      final setKeyRequest = SetKeysRequest(
        kekSalt: keyAttributes.kekSalt,
        encryptedKey: keyAttributes.encryptedKey,
        keyDecryptionNonce: keyAttributes.keyDecryptionNonce,
        memLimit: keyAttributes.memLimit,
        opsLimit: keyAttributes.opsLimit,
      );
      await registerOrUpdateSrp(loginKey, setKeysRequest: setKeyRequest);
      // await _enteDio.put(
      //   "/users/keys",
      //   data: setKeyRequest.toMap(),
      // );
      await _config.setKeyAttributes(keyAttributes);
    } catch (e) {
      _logger.severe(e);
      rethrow;
    }
  }

  Future<void> setRecoveryKey(KeyAttributes keyAttributes) async {
    try {
      final setRecoveryKeyRequest = SetRecoveryKeyRequest(
        keyAttributes.masterKeyEncryptedWithRecoveryKey,
        keyAttributes.masterKeyDecryptionNonce,
        keyAttributes.recoveryKeyEncryptedWithMasterKey,
        keyAttributes.recoveryKeyDecryptionNonce,
      );
      await _enteDio.put(
        "/users/recovery-key",
        data: setRecoveryKeyRequest.toMap(),
      );
      await _config.setKeyAttributes(keyAttributes);
    } catch (e) {
      _logger.severe(e);
      rethrow;
    }
  }

  Future<void> verifyTwoFactor(
      BuildContext context,
      String sessionID,
      String code,
      ) async {
    final dialog = createProgressDialog(context, context.l10n.pleaseWait);
    await dialog.show();
    try {
      final response = await _dio.post(
        _config.getHttpEndpoint() + "/users/two-factor/verify",
        data: {
          "sessionID": sessionID,
          "code": code,
        },
      );
      await dialog.hide();
      if (response.statusCode == 200) {
        showShortToast(context, context.l10n.authenticationSuccessful);
        await _saveConfiguration(response);
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (BuildContext context) {
              return const PasswordReentryPage();
            },
          ),
              (route) => route.isFirst,
        );
      }
    } on DioError catch (e) {
      await dialog.hide();
      _logger.severe(e);
      if (e.response != null && e.response!.statusCode == 404) {
        showToast(context, "Session expired");
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (BuildContext context) {
              return const LoginPage();
            },
          ),
              (route) => route.isFirst,
        );
      } else {
        showErrorDialog(
          context,
          context.l10n.incorrectCode,
          context.l10n.authenticationFailedPleaseTryAgain,
        );
      }
    } catch (e) {
      await dialog.hide();
      _logger.severe(e);
      showErrorDialog(
        context,
        context.l10n.oops,
        context.l10n.authenticationFailedPleaseTryAgain,
      );
    }
  }

  Future<void> recoverTwoFactor(BuildContext context, String sessionID) async {
    final dialog = createProgressDialog(context, context.l10n.pleaseWait);
    await dialog.show();
    try {
      final response = await _dio.get(
        _config.getHttpEndpoint() + "/users/two-factor/recover",
        queryParameters: {
          "sessionID": sessionID,
        },
      );
      if (response.statusCode == 200) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (BuildContext context) {
              return TwoFactorRecoveryPage(
                sessionID,
                response.data["encryptedSecret"],
                response.data["secretDecryptionNonce"],
              );
            },
          ),
              (route) => route.isFirst,
        );
      }
    } on DioError catch (e) {
      _logger.severe(e);
      if (e.response != null && e.response!.statusCode == 404) {
        showToast(context, context.l10n.sessionExpired);
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (BuildContext context) {
              return const LoginPage();
            },
          ),
              (route) => route.isFirst,
        );
      } else {
        showErrorDialog(
          context,
          context.l10n.oops,
          context.l10n.somethingWentWrongPleaseTryAgain,
        );
      }
    } catch (e) {
      _logger.severe(e);
      showErrorDialog(
        context,
        context.l10n.oops,
        context.l10n.somethingWentWrongPleaseTryAgain,
      );
    } finally {
      await dialog.hide();
    }
  }

  Future<void> removeTwoFactor(
      BuildContext context,
      String sessionID,
      String recoveryKey,
      String encryptedSecret,
      String secretDecryptionNonce,
      ) async {
    final dialog = createProgressDialog(context, context.l10n.pleaseWait);
    await dialog.show();
    String secret;
    try {
      if (recoveryKey.contains(' ')) {
        if (recoveryKey.split(' ').length != mnemonicKeyWordCount) {
          throw AssertionError(
            'recovery code should have $mnemonicKeyWordCount words',
          );
        }
        recoveryKey = bip39.mnemonicToEntropy(recoveryKey);
      }
      secret = CryptoUtil.bin2base64(
        await CryptoUtil.decrypt(
          CryptoUtil.base642bin(encryptedSecret),
          CryptoUtil.hex2bin(recoveryKey.trim()),
          CryptoUtil.base642bin(secretDecryptionNonce),
        ),
      );
    } catch (e) {
      await dialog.hide();
      await showErrorDialog(
        context,
        context.l10n.incorrectRecoveryKey,
        context.l10n.theRecoveryKeyYouEnteredIsIncorrect,
      );
      return;
    }
    try {
      final response = await _dio.post(
        _config.getHttpEndpoint() + "/users/two-factor/remove",
        data: {
          "sessionID": sessionID,
          "secret": secret,
        },
      );
      if (response.statusCode == 200) {
        showShortToast(
          context,
          context.l10n.twofactorAuthenticationSuccessfullyReset,
        );
        await _saveConfiguration(response);
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (BuildContext context) {
              return const PasswordReentryPage();
            },
          ),
              (route) => route.isFirst,
        );
      }
    } on DioError catch (e) {
      _logger.severe(e);
      if (e.response != null && e.response!.statusCode == 404) {
        showToast(context, "Session expired");
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (BuildContext context) {
              return const LoginPage();
            },
          ),
              (route) => route.isFirst,
        );
      } else {
        showErrorDialog(
          context,
          context.l10n.oops,
          context.l10n.somethingWentWrongPleaseTryAgain,
        );
      }
    } catch (e) {
      _logger.severe(e);
      showErrorDialog(
        context,
        context.l10n.oops,
        context.l10n.somethingWentWrongPleaseTryAgain,
      );
    } finally {
      await dialog.hide();
    }
  }








  Future<void> _saveConfiguration(Response response) async {
    await Configuration.instance.setUserID(response.data["id"]);
    if (response.data["encryptedToken"] != null) {
      await Configuration.instance
          .setEncryptedToken(response.data["encryptedToken"]);
      await Configuration.instance.setKeyAttributes(
        KeyAttributes.fromMap(response.data["keyAttributes"]),
      );
    } else {
      await Configuration.instance.setToken(response.data["token"]);
    }
  }

  bool? canDisableEmailMFA() {
    return _preferences.getBool(kCanDisableEmailMFA);
  }
  bool hasEmailMFAEnabled() {
    return _preferences.getBool(kIsEmailMFAEnabled) ?? true;
  }

  Future<void> updateEmailMFA(bool isEnabled) async {
    try {
      await _enteDio.put(
        "/users/email-mfa",
        data: {
          "isEnabled": isEnabled,
        },
      );
      _preferences.setBool(kIsEmailMFAEnabled, isEnabled);
    } catch (e) {
      _logger.severe("Failed to update email mfa",e);
      rethrow;
    }
  }
}

