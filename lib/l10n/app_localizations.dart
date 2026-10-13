import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'Cirro Mail'**
  String get appTitle;

  /// No description provided for @servers.
  ///
  /// In en, this message translates to:
  /// **'Servers'**
  String get servers;

  /// No description provided for @addServer.
  ///
  /// In en, this message translates to:
  /// **'Add server'**
  String get addServer;

  /// No description provided for @addInstance.
  ///
  /// In en, this message translates to:
  /// **'Add instance'**
  String get addInstance;

  /// No description provided for @serverAddress.
  ///
  /// In en, this message translates to:
  /// **'Server address'**
  String get serverAddress;

  /// No description provided for @serverAddressHint.
  ///
  /// In en, this message translates to:
  /// **'https://example.com/api'**
  String get serverAddressHint;

  /// No description provided for @testConnection.
  ///
  /// In en, this message translates to:
  /// **'Test connection'**
  String get testConnection;

  /// No description provided for @testing.
  ///
  /// In en, this message translates to:
  /// **'Testing…'**
  String get testing;

  /// No description provided for @connectedTo.
  ///
  /// In en, this message translates to:
  /// **'Connected to {title}'**
  String connectedTo(String title);

  /// No description provided for @addAndSignIn.
  ///
  /// In en, this message translates to:
  /// **'Add and sign in'**
  String get addAndSignIn;

  /// No description provided for @login.
  ///
  /// In en, this message translates to:
  /// **'Sign in'**
  String get login;

  /// No description provided for @logout.
  ///
  /// In en, this message translates to:
  /// **'Sign out'**
  String get logout;

  /// No description provided for @logoutKeepServer.
  ///
  /// In en, this message translates to:
  /// **'Sign out (keep server)'**
  String get logoutKeepServer;

  /// No description provided for @removeServer.
  ///
  /// In en, this message translates to:
  /// **'Remove server'**
  String get removeServer;

  /// No description provided for @removeServerConfirm.
  ///
  /// In en, this message translates to:
  /// **'Remove \"{name}\" and its cached mail?'**
  String removeServerConfirm(String name);

  /// No description provided for @email.
  ///
  /// In en, this message translates to:
  /// **'Email'**
  String get email;

  /// No description provided for @password.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get password;

  /// No description provided for @signingIn.
  ///
  /// In en, this message translates to:
  /// **'Signing in…'**
  String get signingIn;

  /// No description provided for @nickname.
  ///
  /// In en, this message translates to:
  /// **'Nickname'**
  String get nickname;

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @confirm.
  ///
  /// In en, this message translates to:
  /// **'Confirm'**
  String get confirm;

  /// No description provided for @retry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retry;

  /// No description provided for @copied.
  ///
  /// In en, this message translates to:
  /// **'Copied'**
  String get copied;

  /// No description provided for @copy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get copy;

  /// No description provided for @all.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get all;

  /// No description provided for @aggregateInbox.
  ///
  /// In en, this message translates to:
  /// **'All mail'**
  String get aggregateInbox;

  /// No description provided for @markAllRead.
  ///
  /// In en, this message translates to:
  /// **'Mark all read'**
  String get markAllRead;

  /// No description provided for @markRead.
  ///
  /// In en, this message translates to:
  /// **'Mark read'**
  String get markRead;

  /// No description provided for @markUnread.
  ///
  /// In en, this message translates to:
  /// **'Mark unread'**
  String get markUnread;

  /// No description provided for @refresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get refresh;

  /// No description provided for @settings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settings;

  /// No description provided for @diagnostics.
  ///
  /// In en, this message translates to:
  /// **'Diagnostics'**
  String get diagnostics;

  /// No description provided for @inbox.
  ///
  /// In en, this message translates to:
  /// **'Inbox'**
  String get inbox;

  /// No description provided for @sent.
  ///
  /// In en, this message translates to:
  /// **'Sent'**
  String get sent;

  /// No description provided for @starred.
  ///
  /// In en, this message translates to:
  /// **'Starred'**
  String get starred;

  /// No description provided for @star.
  ///
  /// In en, this message translates to:
  /// **'Star'**
  String get star;

  /// No description provided for @unstar.
  ///
  /// In en, this message translates to:
  /// **'Unstar'**
  String get unstar;

  /// No description provided for @newMail.
  ///
  /// In en, this message translates to:
  /// **'New mail'**
  String get newMail;

  /// No description provided for @newMailSummary.
  ///
  /// In en, this message translates to:
  /// **'{name}: {count} new messages'**
  String newMailSummary(String name, int count);

  /// No description provided for @notifyBanner.
  ///
  /// In en, this message translates to:
  /// **'In-app banner'**
  String get notifyBanner;

  /// No description provided for @notifyBannerHint.
  ///
  /// In en, this message translates to:
  /// **'Turning this off still fetches mail (the list keeps updating) — it just stops the pop-ups.'**
  String get notifyBannerHint;

  /// No description provided for @pushTitle.
  ///
  /// In en, this message translates to:
  /// **'Background push (FCM)'**
  String get pushTitle;

  /// No description provided for @pushShort.
  ///
  /// In en, this message translates to:
  /// **'Push'**
  String get pushShort;

  /// No description provided for @pushHint.
  ///
  /// In en, this message translates to:
  /// **'When the app is backgrounded or frozen by the system, a relay delivers new-mail alerts. You can skip this — you just won\'t be alerted in the background.'**
  String get pushHint;

  /// No description provided for @pushRelayUrl.
  ///
  /// In en, this message translates to:
  /// **'Relay URL'**
  String get pushRelayUrl;

  /// No description provided for @pushRelayUrlHint.
  ///
  /// In en, this message translates to:
  /// **'Your self-hosted mail-push worker, e.g. https://push.example.com'**
  String get pushRelayUrlHint;

  /// No description provided for @pushInstanceId.
  ///
  /// In en, this message translates to:
  /// **'Instance slot id'**
  String get pushInstanceId;

  /// No description provided for @pushInstanceIdHint.
  ///
  /// In en, this message translates to:
  /// **'The id your deployment\'s /admin/instances created'**
  String get pushInstanceIdHint;

  /// No description provided for @pushPairingCode.
  ///
  /// In en, this message translates to:
  /// **'Pairing code'**
  String get pushPairingCode;

  /// No description provided for @pushPairingCodeHint.
  ///
  /// In en, this message translates to:
  /// **'Shown once when the slot was created; rotate if you lost it'**
  String get pushPairingCodeHint;

  /// No description provided for @pushDeviceId.
  ///
  /// In en, this message translates to:
  /// **'Device id'**
  String get pushDeviceId;

  /// No description provided for @pushDeviceIdHint.
  ///
  /// In en, this message translates to:
  /// **'Generated automatically on this device and tied to the slot id — you never need to edit it. Handy for support: it\'s what the relay knows this device as.'**
  String get pushDeviceIdHint;

  /// No description provided for @pushEnable.
  ///
  /// In en, this message translates to:
  /// **'Enable background push'**
  String get pushEnable;

  /// No description provided for @pushEnabledHint.
  ///
  /// In en, this message translates to:
  /// **'Affects background alerts only — foreground sync, polling and in-app banners are unaffected.'**
  String get pushEnabledHint;

  /// No description provided for @pushRegister.
  ///
  /// In en, this message translates to:
  /// **'Register this device'**
  String get pushRegister;

  /// No description provided for @pushUnregister.
  ///
  /// In en, this message translates to:
  /// **'Unsubscribe'**
  String get pushUnregister;

  /// No description provided for @pushTestOk.
  ///
  /// In en, this message translates to:
  /// **'Relay reachable'**
  String get pushTestOk;

  /// No description provided for @pushRegistrations.
  ///
  /// In en, this message translates to:
  /// **'Mailboxes on the relay'**
  String get pushRegistrations;

  /// No description provided for @pushRegistrationsEmpty.
  ///
  /// In en, this message translates to:
  /// **'This device isn\'t registered for any mailbox yet'**
  String get pushRegistrationsEmpty;

  /// No description provided for @pushUnsupported.
  ///
  /// In en, this message translates to:
  /// **'No FCM implementation on this platform (only Linux / Windows — those rely on the app polling while it runs).'**
  String get pushUnsupported;

  /// No description provided for @pushNotConfigured.
  ///
  /// In en, this message translates to:
  /// **'Relay settings aren\'t filled in — mail arrives only while the app is running.'**
  String get pushNotConfigured;

  /// No description provided for @pushNoFirebaseConfig.
  ///
  /// In en, this message translates to:
  /// **'This build has no Firebase config file (google-services.json / GoogleService-Info.plist), so FCM is unavailable. Create a Firebase project and rebuild.'**
  String get pushNoFirebaseConfig;

  /// No description provided for @pushRelayFcmMissing.
  ///
  /// In en, this message translates to:
  /// **'The relay has no FCM service account configured, so nothing can be delivered.'**
  String get pushRelayFcmMissing;

  /// No description provided for @pushWebhookHint.
  ///
  /// In en, this message translates to:
  /// **'Paste these two into the \"Webhook push\" settings of *your* cloud-mail instance, then turn that switch on. This step can only be done by you — the relay doesn\'t know the instance\'s login system and can\'t do it for you.'**
  String get pushWebhookHint;

  /// No description provided for @pushWebhookUrl.
  ///
  /// In en, this message translates to:
  /// **'Webhook URL'**
  String get pushWebhookUrl;

  /// No description provided for @pushWebhookSecret.
  ///
  /// In en, this message translates to:
  /// **'Webhook secret'**
  String get pushWebhookSecret;

  /// No description provided for @pushWebhookNoSecret.
  ///
  /// In en, this message translates to:
  /// **'No pairing code yet, so no secret to show'**
  String get pushWebhookNoSecret;

  /// No description provided for @pushCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get pushCopy;

  /// No description provided for @pushCopied.
  ///
  /// In en, this message translates to:
  /// **'Copied'**
  String get pushCopied;

  /// No description provided for @pushChecking.
  ///
  /// In en, this message translates to:
  /// **'Checking…'**
  String get pushChecking;

  /// No description provided for @pushSelfCheckOk.
  ///
  /// In en, this message translates to:
  /// **'Pairing code and URL both check out'**
  String get pushSelfCheckOk;

  /// No description provided for @pushSelfCheckSecretBad.
  ///
  /// In en, this message translates to:
  /// **'Wrong pairing code — this slot\'s secret was rotated; get a fresh one'**
  String get pushSelfCheckSecretBad;

  /// No description provided for @pushSelfCheckUrlBad.
  ///
  /// In en, this message translates to:
  /// **'Wrong URL — it must include the /<slot>/webhook part'**
  String get pushSelfCheckUrlBad;

  /// No description provided for @pushSelfCheckNoEventYet.
  ///
  /// In en, this message translates to:
  /// **'Config looks fine, but this slot has never actually received an event — remember to save it in the instance admin and turn the switch on.'**
  String get pushSelfCheckNoEventYet;

  /// No description provided for @pushSelfCheckGotEvent.
  ///
  /// In en, this message translates to:
  /// **'Last webhook received: {time}'**
  String pushSelfCheckGotEvent(String time);

  /// No description provided for @pushNeedLoginFirst.
  ///
  /// In en, this message translates to:
  /// **'Fill in the pairing code and slot id above first, so the self-check knows what to ask about.'**
  String get pushNeedLoginFirst;

  /// No description provided for @pushLimits.
  ///
  /// In en, this message translates to:
  /// **'Limits (worth knowing up front)'**
  String get pushLimits;

  /// No description provided for @pushLimit1.
  ///
  /// In en, this message translates to:
  /// **'External mail only: mail sent inside the instance, and mail from other clients, never triggers a push — only polling sees those.'**
  String get pushLimit1;

  /// No description provided for @pushLimit2.
  ///
  /// In en, this message translates to:
  /// **'If the instance is set to rule-based receiving, the webhook never fires.'**
  String get pushLimit2;

  /// No description provided for @pushLimit3.
  ///
  /// In en, this message translates to:
  /// **'The push carries metadata only (sender / subject / code); the app still fetches the body from the instance with its own token.'**
  String get pushLimit3;

  /// No description provided for @pushLimit4.
  ///
  /// In en, this message translates to:
  /// **'The relay can see the metadata of every instance\'s mail — if you self-host it, that\'s you.'**
  String get pushLimit4;

  /// No description provided for @pushAdvanced.
  ///
  /// In en, this message translates to:
  /// **'Advanced'**
  String get pushAdvanced;

  /// No description provided for @pushPageStepOf.
  ///
  /// In en, this message translates to:
  /// **'Step {index} of {total}'**
  String pushPageStepOf(int index, int total);

  /// No description provided for @pushPageBack.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get pushPageBack;

  /// No description provided for @pushPageNext.
  ///
  /// In en, this message translates to:
  /// **'Next'**
  String get pushPageNext;

  /// No description provided for @pushPageDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get pushPageDone;

  /// No description provided for @pushPageRecheck.
  ///
  /// In en, this message translates to:
  /// **'Re-check status'**
  String get pushPageRecheck;

  /// No description provided for @pushPageStatusTitle.
  ///
  /// In en, this message translates to:
  /// **'Is push working right now?'**
  String get pushPageStatusTitle;

  /// No description provided for @pushPageStatusBody.
  ///
  /// In en, this message translates to:
  /// **'Three things are independent: this platform, the three relay values, and whether this device is registered. If any one of them is missing, nothing reaches you while the app is closed.'**
  String get pushPageStatusBody;

  /// No description provided for @pushPageStatusPlatform.
  ///
  /// In en, this message translates to:
  /// **'This platform supports FCM'**
  String get pushPageStatusPlatform;

  /// No description provided for @pushPageStatusOk.
  ///
  /// In en, this message translates to:
  /// **'Looks good'**
  String get pushPageStatusOk;

  /// No description provided for @pushPageStatusConfigured.
  ///
  /// In en, this message translates to:
  /// **'The three relay values are filled in'**
  String get pushPageStatusConfigured;

  /// No description provided for @pushPageStatusRegisteredCount.
  ///
  /// In en, this message translates to:
  /// **'Registered: {count}'**
  String pushPageStatusRegisteredCount(int count);

  /// No description provided for @pushPageStatusOff.
  ///
  /// In en, this message translates to:
  /// **'The master switch is off — none of the steps below will happen.'**
  String get pushPageStatusOff;

  /// No description provided for @pushPageStatusGo.
  ///
  /// In en, this message translates to:
  /// **'Turn the switch on'**
  String get pushPageStatusGo;

  /// No description provided for @pushPageValuesTitle.
  ///
  /// In en, this message translates to:
  /// **'Enter the three values'**
  String get pushPageValuesTitle;

  /// No description provided for @pushPageValuesBody.
  ///
  /// In en, this message translates to:
  /// **'All three come from the relay: the URL is the worker\'s domain, the slot id is the slot it created for you, and the pairing code is shown once, at creation.'**
  String get pushPageValuesBody;

  /// No description provided for @pushPageValuesSave.
  ///
  /// In en, this message translates to:
  /// **'Save these three values'**
  String get pushPageValuesSave;

  /// No description provided for @pushPageValuesSaved.
  ///
  /// In en, this message translates to:
  /// **'Saved'**
  String get pushPageValuesSaved;

  /// No description provided for @pushPageValuesKeep.
  ///
  /// In en, this message translates to:
  /// **'The pairing code is shown once, when a slot is created; neither backend can read it back. If you lose it, rotate the slot.'**
  String get pushPageValuesKeep;

  /// No description provided for @pushPageValuesProvision.
  ///
  /// In en, this message translates to:
  /// **'I run the relay — create a new slot'**
  String get pushPageValuesProvision;

  /// No description provided for @pushPageEnableTitle.
  ///
  /// In en, this message translates to:
  /// **'Turn on background push'**
  String get pushPageEnableTitle;

  /// No description provided for @pushPageEnableBody.
  ///
  /// In en, this message translates to:
  /// **'This switch only governs alerts while the app isn\'t in the foreground — foreground sync, polling and in-app banners are unaffected.'**
  String get pushPageEnableBody;

  /// No description provided for @pushPageEnableOff.
  ///
  /// In en, this message translates to:
  /// **'Turning the switch off also unsubscribes, so the relay stops pushing to this device.'**
  String get pushPageEnableOff;

  /// No description provided for @pushPageEnrollTitle.
  ///
  /// In en, this message translates to:
  /// **'Register this device'**
  String get pushPageEnrollTitle;

  /// No description provided for @pushPageEnrollBody.
  ///
  /// In en, this message translates to:
  /// **'Binds each mailbox to this device\'s FCM token. It also runs automatically on launch, so this step is mainly here to confirm it worked.'**
  String get pushPageEnrollBody;

  /// No description provided for @pushPageEnrollPermission.
  ///
  /// In en, this message translates to:
  /// **'The first time you register, the system asks for notification permission — that prompt is this step.'**
  String get pushPageEnrollPermission;

  /// No description provided for @pushPageEnrollBlocked.
  ///
  /// In en, this message translates to:
  /// **'Fill in the three values on step 2 and turn the switch on in step 3 first.'**
  String get pushPageEnrollBlocked;

  /// No description provided for @pushPageEnrollUnsubHint.
  ///
  /// In en, this message translates to:
  /// **'Unsubscribe removes every registration for this device on the relay — no more pushes after that.'**
  String get pushPageEnrollUnsubHint;

  /// No description provided for @pushPageWebhookTitle.
  ///
  /// In en, this message translates to:
  /// **'Turn on Webhook push in your instance\'s admin'**
  String get pushPageWebhookTitle;

  /// No description provided for @pushPageWebhookBody.
  ///
  /// In en, this message translates to:
  /// **'This is the one step that must be done on another site, and the one people most often forget.'**
  String get pushPageWebhookBody;

  /// No description provided for @pushPageWebhookAdminAsk.
  ///
  /// In en, this message translates to:
  /// **'Do you run this cloud-mail instance?'**
  String get pushPageWebhookAdminAsk;

  /// No description provided for @pushPageWebhookAdminYes.
  ///
  /// In en, this message translates to:
  /// **'Yes — I\'ll fill it in'**
  String get pushPageWebhookAdminYes;

  /// No description provided for @pushPageWebhookAdminNo.
  ///
  /// In en, this message translates to:
  /// **'No — send it to the admin'**
  String get pushPageWebhookAdminNo;

  /// No description provided for @pushPageWebhookAdminOtherHint.
  ///
  /// In en, this message translates to:
  /// **'Copy the message below and send it to whoever runs your instance.'**
  String get pushPageWebhookAdminOtherHint;

  /// No description provided for @pushPageWebhookRelayCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy a message to send'**
  String get pushPageWebhookRelayCopy;

  /// No description provided for @pushPageWebhookRelayMessage.
  ///
  /// In en, this message translates to:
  /// **'Please open \"Webhook push\" in the cloud-mail instance admin, fill in the URL {url} and the secret {code}, and turn that switch on. New mail can only reach my phone after that.'**
  String pushPageWebhookRelayMessage(String url, String code);

  /// No description provided for @pushPageWebhookStatus0.
  ///
  /// In en, this message translates to:
  /// **'Note: that switch is stored as webhookStatus, and 0 means enabled — the field name reads backwards, so it is the first suspect when nothing arrives.'**
  String get pushPageWebhookStatus0;

  /// No description provided for @pushPageWebhookConfirm.
  ///
  /// In en, this message translates to:
  /// **'I\'ve filled in both values in the instance admin, and turned Webhook push on'**
  String get pushPageWebhookConfirm;

  /// No description provided for @pushPageWebhookConfirmed.
  ///
  /// In en, this message translates to:
  /// **'Confirmed. Change the URL or the pairing code above and this step needs confirming again.'**
  String get pushPageWebhookConfirmed;

  /// No description provided for @pushPageWebhookUnconfirmed.
  ///
  /// In en, this message translates to:
  /// **'That part happens on another site, so the app can\'t see it — you have to tick the box yourself, otherwise this step keeps reading as not done.'**
  String get pushPageWebhookUnconfirmed;

  /// No description provided for @pushPageWebhookEvidence.
  ///
  /// In en, this message translates to:
  /// **'The relay has already received a webhook ({time}) — this step works, no confirmation needed.'**
  String pushPageWebhookEvidence(String time);

  /// No description provided for @pushPageCheckRememberedAt.
  ///
  /// In en, this message translates to:
  /// **'The last check passed ({time}) and nothing above has changed — it stays remembered.'**
  String pushPageCheckRememberedAt(String time);

  /// No description provided for @pushPageCheckNever.
  ///
  /// In en, this message translates to:
  /// **'Not checked yet. Tap the button above once; the result is remembered.'**
  String get pushPageCheckNever;

  /// No description provided for @pushRefreshed.
  ///
  /// In en, this message translates to:
  /// **'Refreshed: the relay has {count} mailbox(es)'**
  String pushRefreshed(int count);

  /// No description provided for @pushRefreshedEmpty.
  ///
  /// In en, this message translates to:
  /// **'Refreshed: the relay has no mailboxes registered yet'**
  String get pushRefreshedEmpty;

  /// No description provided for @pushRegistering.
  ///
  /// In en, this message translates to:
  /// **'Registering…'**
  String get pushRegistering;

  /// No description provided for @pushUnregistering.
  ///
  /// In en, this message translates to:
  /// **'Unsubscribing…'**
  String get pushUnregistering;

  /// No description provided for @pushRefreshing.
  ///
  /// In en, this message translates to:
  /// **'Refreshing…'**
  String get pushRefreshing;

  /// No description provided for @pushPageCheckTitle.
  ///
  /// In en, this message translates to:
  /// **'Check the whole chain'**
  String get pushPageCheckTitle;

  /// No description provided for @pushPageCheckBody.
  ///
  /// In en, this message translates to:
  /// **'One pass answers four things: can the relay be reached, does it have FCM, is this pairing code right, and is the URL saved in your instance correct.'**
  String get pushPageCheckBody;

  /// No description provided for @pushPageCheckAction.
  ///
  /// In en, this message translates to:
  /// **'Check this chain'**
  String get pushPageCheckAction;

  /// No description provided for @pushPageCheckStale.
  ///
  /// In en, this message translates to:
  /// **'You changed the values above — run the check again for a fresh result.'**
  String get pushPageCheckStale;

  /// No description provided for @pushPageCheckFcmOk.
  ///
  /// In en, this message translates to:
  /// **'The relay has an FCM service account'**
  String get pushPageCheckFcmOk;

  /// No description provided for @pushPageNotesTitle.
  ///
  /// In en, this message translates to:
  /// **'A few things worth knowing first'**
  String get pushPageNotesTitle;

  /// No description provided for @pushPageNotesBody.
  ///
  /// In en, this message translates to:
  /// **'Background push is deliberately narrow: it covers external mail only, and everything else still arrives through polling.'**
  String get pushPageNotesBody;

  /// No description provided for @pushPageNotesTurnOff.
  ///
  /// In en, this message translates to:
  /// **'How to turn it off'**
  String get pushPageNotesTurnOff;

  /// No description provided for @pushPageNotesTurnOffBody.
  ///
  /// In en, this message translates to:
  /// **'Go back to step 3 and turn the switch off; the app unsubscribes for you.'**
  String get pushPageNotesTurnOffBody;

  /// No description provided for @pushPageNotesSwitchSlot.
  ///
  /// In en, this message translates to:
  /// **'If you switch to another slot'**
  String get pushPageNotesSwitchSlot;

  /// No description provided for @pushPageNotesSwitchSlotBody.
  ///
  /// In en, this message translates to:
  /// **'The app unsubscribes from the old slot automatically — there is nothing to clean up by hand.'**
  String get pushPageNotesSwitchSlotBody;

  /// No description provided for @pushPageDocsHint.
  ///
  /// In en, this message translates to:
  /// **'Full commands and troubleshooting are in docs/push-setup.md in the repository.'**
  String get pushPageDocsHint;

  /// No description provided for @compose.
  ///
  /// In en, this message translates to:
  /// **'Compose'**
  String get compose;

  /// No description provided for @composeSectionSignatures.
  ///
  /// In en, this message translates to:
  /// **'Signatures'**
  String get composeSectionSignatures;

  /// No description provided for @composeSignatureFor.
  ///
  /// In en, this message translates to:
  /// **'Signature for {email}'**
  String composeSignatureFor(String email);

  /// No description provided for @composePhrases.
  ///
  /// In en, this message translates to:
  /// **'Common phrases'**
  String get composePhrases;

  /// No description provided for @composePhrasesFor.
  ///
  /// In en, this message translates to:
  /// **'Common phrases for {email}'**
  String composePhrasesFor(String email);

  /// No description provided for @composePhraseName.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get composePhraseName;

  /// No description provided for @composePhraseText.
  ///
  /// In en, this message translates to:
  /// **'Text'**
  String get composePhraseText;

  /// No description provided for @composeSignatureEmpty.
  ///
  /// In en, this message translates to:
  /// **'No mailbox yet — add an instance first'**
  String get composeSignatureEmpty;

  /// No description provided for @composeSnippetsHint.
  ///
  /// In en, this message translates to:
  /// **'Signatures and phrases are shared across instances by email address'**
  String get composeSnippetsHint;

  /// No description provided for @noMailbox.
  ///
  /// In en, this message translates to:
  /// **'No mailbox available'**
  String get noMailbox;

  /// No description provided for @needAccountPerm.
  ///
  /// In en, this message translates to:
  /// **'This account can\'t list mailboxes (missing \"account:query\" permission); showing the primary mailbox only.'**
  String get needAccountPerm;

  /// No description provided for @emptyList.
  ///
  /// In en, this message translates to:
  /// **'No mail'**
  String get emptyList;

  /// No description provided for @loadFailed.
  ///
  /// In en, this message translates to:
  /// **'Load failed'**
  String get loadFailed;

  /// No description provided for @attachmentUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Attachment unavailable'**
  String get attachmentUnavailable;

  /// No description provided for @serverUnreachable.
  ///
  /// In en, this message translates to:
  /// **'Server unreachable'**
  String get serverUnreachable;

  /// No description provided for @sessionExpired.
  ///
  /// In en, this message translates to:
  /// **'Session expired, sign in again'**
  String get sessionExpired;

  /// No description provided for @sessionExpiredHint.
  ///
  /// In en, this message translates to:
  /// **'The sign-in may have been replaced by another device (one account allows 10 sessions).'**
  String get sessionExpiredHint;

  /// No description provided for @needsLogin.
  ///
  /// In en, this message translates to:
  /// **'Needs sign-in'**
  String get needsLogin;

  /// No description provided for @syncNow.
  ///
  /// In en, this message translates to:
  /// **'Sync now'**
  String get syncNow;

  /// No description provided for @close.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get close;

  /// No description provided for @switchMailbox.
  ///
  /// In en, this message translates to:
  /// **'Switch mailbox'**
  String get switchMailbox;

  /// No description provided for @pickMail.
  ///
  /// In en, this message translates to:
  /// **'Pick a mail'**
  String get pickMail;

  /// No description provided for @syncing.
  ///
  /// In en, this message translates to:
  /// **'Syncing'**
  String get syncing;

  /// No description provided for @lastSync.
  ///
  /// In en, this message translates to:
  /// **'Last sync {time}'**
  String lastSync(String time);

  /// No description provided for @pollInterval.
  ///
  /// In en, this message translates to:
  /// **'Check for mail every'**
  String get pollInterval;

  /// No description provided for @pollIntervalHint.
  ///
  /// In en, this message translates to:
  /// **'How often new mail is fetched (1 minute – 1 hour). Shorter is more timely and uses more battery.'**
  String get pollIntervalHint;

  /// No description provided for @minutesCount.
  ///
  /// In en, this message translates to:
  /// **'{minutes} min'**
  String minutesCount(int minutes);

  /// No description provided for @notifications.
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get notifications;

  /// No description provided for @notifyEnabledHint.
  ///
  /// In en, this message translates to:
  /// **'Turning this off stops polling and new-mail alerts; mail you already received stays readable.'**
  String get notifyEnabledHint;

  /// No description provided for @clearCache.
  ///
  /// In en, this message translates to:
  /// **'Clear cache'**
  String get clearCache;

  /// No description provided for @unnamed.
  ///
  /// In en, this message translates to:
  /// **'(unnamed)'**
  String get unnamed;

  /// No description provided for @unknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get unknown;

  /// No description provided for @noSubject.
  ///
  /// In en, this message translates to:
  /// **'(no subject)'**
  String get noSubject;

  /// No description provided for @pageNotFound.
  ///
  /// In en, this message translates to:
  /// **'Page not found'**
  String get pageNotFound;

  /// No description provided for @cannotOpen.
  ///
  /// In en, this message translates to:
  /// **'Can\'t open: {uri}'**
  String cannotOpen(String uri);

  /// No description provided for @backToInbox.
  ///
  /// In en, this message translates to:
  /// **'Back to inbox'**
  String get backToInbox;

  /// No description provided for @startupFailed.
  ///
  /// In en, this message translates to:
  /// **'Startup failed'**
  String get startupFailed;

  /// No description provided for @startupFailedHint.
  ///
  /// In en, this message translates to:
  /// **'Local data couldn\'t be opened, so the app can\'t continue. The reason is below.'**
  String get startupFailedHint;

  /// No description provided for @keystoreDegraded.
  ///
  /// In en, this message translates to:
  /// **'The system keystore is unavailable; sign-in state will only live in memory and must be entered again after a restart.'**
  String get keystoreDegraded;

  /// No description provided for @removeServerLostDrafts.
  ///
  /// In en, this message translates to:
  /// **'If it keeps failing, remove the instance and add it again (unsent drafts will be lost).'**
  String get removeServerLostDrafts;

  /// No description provided for @instances.
  ///
  /// In en, this message translates to:
  /// **'Instances'**
  String get instances;

  /// No description provided for @noInstances.
  ///
  /// In en, this message translates to:
  /// **'No instances yet'**
  String get noInstances;

  /// No description provided for @addFirstInstance.
  ///
  /// In en, this message translates to:
  /// **'Add your first instance'**
  String get addFirstInstance;

  /// No description provided for @editInstance.
  ///
  /// In en, this message translates to:
  /// **'Edit instance'**
  String get editInstance;

  /// No description provided for @edit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get edit;

  /// No description provided for @instanceName.
  ///
  /// In en, this message translates to:
  /// **'Instance name'**
  String get instanceName;

  /// No description provided for @connectionOk.
  ///
  /// In en, this message translates to:
  /// **'Connection OK'**
  String get connectionOk;

  /// No description provided for @connectionFailed.
  ///
  /// In en, this message translates to:
  /// **'Connection failed'**
  String get connectionFailed;

  /// No description provided for @checkAddress.
  ///
  /// In en, this message translates to:
  /// **'Check the server address and your network.'**
  String get checkAddress;

  /// No description provided for @serverAddressRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter the server address'**
  String get serverAddressRequired;

  /// No description provided for @emailRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter your email'**
  String get emailRequired;

  /// No description provided for @passwordRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter your password'**
  String get passwordRequired;

  /// No description provided for @loginFailed.
  ///
  /// In en, this message translates to:
  /// **'Sign-in failed'**
  String get loginFailed;

  /// No description provided for @signedInAs.
  ///
  /// In en, this message translates to:
  /// **'Signed in as {email}'**
  String signedInAs(String email);

  /// No description provided for @instanceNeedsLoginHint.
  ///
  /// In en, this message translates to:
  /// **'The session for this instance expired. Sign in again — other instances are unaffected.'**
  String get instanceNeedsLoginHint;

  /// No description provided for @noInstancesLoggedIn.
  ///
  /// In en, this message translates to:
  /// **'No instance is signed in'**
  String get noInstancesLoggedIn;

  /// No description provided for @polling.
  ///
  /// In en, this message translates to:
  /// **'Polling'**
  String get polling;

  /// No description provided for @appearance.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get appearance;

  /// No description provided for @theme.
  ///
  /// In en, this message translates to:
  /// **'Theme'**
  String get theme;

  /// No description provided for @themeSystem.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get themeSystem;

  /// No description provided for @themeLight.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get themeLight;

  /// No description provided for @themeDark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get themeDark;

  /// No description provided for @language.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get language;

  /// No description provided for @languageSystem.
  ///
  /// In en, this message translates to:
  /// **'Follow system'**
  String get languageSystem;

  /// No description provided for @about.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get about;

  /// No description provided for @version.
  ///
  /// In en, this message translates to:
  /// **'Version'**
  String get version;

  /// No description provided for @capabilities.
  ///
  /// In en, this message translates to:
  /// **'Capabilities'**
  String get capabilities;

  /// No description provided for @syncStatus.
  ///
  /// In en, this message translates to:
  /// **'Sync status'**
  String get syncStatus;

  /// No description provided for @intervalLabel.
  ///
  /// In en, this message translates to:
  /// **'Interval'**
  String get intervalLabel;

  /// No description provided for @lastSyncAt.
  ///
  /// In en, this message translates to:
  /// **'Last sync: {time}'**
  String lastSyncAt(String time);

  /// No description provided for @consecutiveFailures.
  ///
  /// In en, this message translates to:
  /// **'Consecutive failures'**
  String get consecutiveFailures;

  /// No description provided for @cursor.
  ///
  /// In en, this message translates to:
  /// **'Cursor'**
  String get cursor;

  /// No description provided for @endpointSelfCheck.
  ///
  /// In en, this message translates to:
  /// **'Endpoint self-check'**
  String get endpointSelfCheck;

  /// No description provided for @rawEnvelope.
  ///
  /// In en, this message translates to:
  /// **'Raw response'**
  String get rawEnvelope;

  /// No description provided for @notFoundInWindow.
  ///
  /// In en, this message translates to:
  /// **'This message isn\'t in the loaded window yet.'**
  String get notFoundInWindow;

  /// No description provided for @openExternally.
  ///
  /// In en, this message translates to:
  /// **'Open in browser'**
  String get openExternally;

  /// No description provided for @probeNotRun.
  ///
  /// In en, this message translates to:
  /// **'Not probed'**
  String get probeNotRun;

  /// No description provided for @send.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get send;

  /// No description provided for @sendFailed.
  ///
  /// In en, this message translates to:
  /// **'Send failed'**
  String get sendFailed;

  /// No description provided for @composeTo.
  ///
  /// In en, this message translates to:
  /// **'To'**
  String get composeTo;

  /// No description provided for @composeSubject.
  ///
  /// In en, this message translates to:
  /// **'Subject'**
  String get composeSubject;

  /// No description provided for @composeBody.
  ///
  /// In en, this message translates to:
  /// **'Message'**
  String get composeBody;

  /// No description provided for @removeInstance.
  ///
  /// In en, this message translates to:
  /// **'Remove instance'**
  String get removeInstance;

  /// No description provided for @checkingSession.
  ///
  /// In en, this message translates to:
  /// **'Checking session…'**
  String get checkingSession;

  /// No description provided for @setAsCurrent.
  ///
  /// In en, this message translates to:
  /// **'Set as current'**
  String get setAsCurrent;

  /// No description provided for @setAsCurrentOk.
  ///
  /// In en, this message translates to:
  /// **'Now showing {name}'**
  String setAsCurrentOk(Object name);

  /// No description provided for @removeInstanceConfirm.
  ///
  /// In en, this message translates to:
  /// **'Remove \"{name}\" and all of its cached mail?'**
  String removeInstanceConfirm(Object name);

  /// No description provided for @signOutConfirm.
  ///
  /// In en, this message translates to:
  /// **'Sign out of \"{name}\"? Mail that has not been sent will be kept.'**
  String signOutConfirm(Object name);

  /// No description provided for @prefetchTitle.
  ///
  /// In en, this message translates to:
  /// **'Prefetch full bodies'**
  String get prefetchTitle;

  /// No description provided for @prefetchHint.
  ///
  /// In en, this message translates to:
  /// **'Pulls full=1 while paging so messages open instantly; turn off to save data'**
  String get prefetchHint;

  /// No description provided for @selfCheckHint.
  ///
  /// In en, this message translates to:
  /// **'Tap to hit the key endpoints once and see what the server actually returns'**
  String get selfCheckHint;

  /// No description provided for @selfCheckLoginFirst.
  ///
  /// In en, this message translates to:
  /// **'Sign in first — these endpoints would only return 401'**
  String get selfCheckLoginFirst;

  /// No description provided for @noMailboxCache.
  ///
  /// In en, this message translates to:
  /// **'No mailbox cache yet'**
  String get noMailboxCache;

  /// No description provided for @noScheduler.
  ///
  /// In en, this message translates to:
  /// **'Scheduler not running — no instance is signed in, or polling is paused'**
  String get noScheduler;

  /// No description provided for @allMailboxes.
  ///
  /// In en, this message translates to:
  /// **'All mailboxes'**
  String get allMailboxes;

  /// No description provided for @lastSyncedAt.
  ///
  /// In en, this message translates to:
  /// **'Last sync'**
  String get lastSyncedAt;

  /// No description provided for @domainList.
  ///
  /// In en, this message translates to:
  /// **'Domains'**
  String get domainList;

  /// No description provided for @siteConfig.
  ///
  /// In en, this message translates to:
  /// **'Site config'**
  String get siteConfig;

  /// No description provided for @probedAt.
  ///
  /// In en, this message translates to:
  /// **'Probed at'**
  String get probedAt;

  /// No description provided for @fieldTitle.
  ///
  /// In en, this message translates to:
  /// **'title'**
  String get fieldTitle;

  /// No description provided for @fieldR2Domain.
  ///
  /// In en, this message translates to:
  /// **'r2Domain'**
  String get fieldR2Domain;

  /// No description provided for @missingGoesOssApi.
  ///
  /// In en, this message translates to:
  /// **'missing (using /api/oss/)'**
  String get missingGoesOssApi;

  /// No description provided for @mailbox.
  ///
  /// In en, this message translates to:
  /// **'Mailboxes'**
  String get mailbox;

  /// sidebar: disclosure arrow on a profile row (per-instance, unlike toggleMailboxList which is the whole group)
  ///
  /// In en, this message translates to:
  /// **'Show or hide this instance\'s mailboxes'**
  String get toggleInstanceMailboxList;

  /// sidebar: placeholder for a mailbox total that has not been probed yet
  ///
  /// In en, this message translates to:
  /// **'—'**
  String get mailboxCountUnknown;

  /// sidebar: screen-reader label for the unread/total pair (the visible text is symbols only)
  ///
  /// In en, this message translates to:
  /// **'{total} messages, {unread} unread'**
  String mailboxCountsLabel(int unread, int total);

  /// No description provided for @nicknameHint.
  ///
  /// In en, this message translates to:
  /// **'Falls back to the site title or your email'**
  String get nicknameHint;

  /// No description provided for @download.
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get download;

  /// No description provided for @downloading.
  ///
  /// In en, this message translates to:
  /// **'Downloading…'**
  String get downloading;

  /// No description provided for @openWith.
  ///
  /// In en, this message translates to:
  /// **'Open with another app'**
  String get openWith;

  /// No description provided for @share.
  ///
  /// In en, this message translates to:
  /// **'Share'**
  String get share;

  /// No description provided for @saveAs.
  ///
  /// In en, this message translates to:
  /// **'Save as'**
  String get saveAs;

  /// No description provided for @preview.
  ///
  /// In en, this message translates to:
  /// **'Preview'**
  String get preview;

  /// No description provided for @attachmentDownloaded.
  ///
  /// In en, this message translates to:
  /// **'Downloaded'**
  String get attachmentDownloaded;

  /// No description provided for @attachmentDeleted.
  ///
  /// In en, this message translates to:
  /// **'Local copy deleted'**
  String get attachmentDeleted;

  /// No description provided for @attachmentCache.
  ///
  /// In en, this message translates to:
  /// **'Attachment cache'**
  String get attachmentCache;

  /// No description provided for @attachmentCacheHint.
  ///
  /// In en, this message translates to:
  /// **'Downloaded attachments are kept here for offline use'**
  String get attachmentCacheHint;

  /// No description provided for @cacheEmpty.
  ///
  /// In en, this message translates to:
  /// **'No attachments downloaded yet'**
  String get cacheEmpty;

  /// No description provided for @pickAttachment.
  ///
  /// In en, this message translates to:
  /// **'Pick an attachment'**
  String get pickAttachment;

  /// No description provided for @cacheUsage.
  ///
  /// In en, this message translates to:
  /// **'{files} files · {size}'**
  String cacheUsage(int files, String size);

  /// No description provided for @clearAllAttachments.
  ///
  /// In en, this message translates to:
  /// **'Clear all attachments'**
  String get clearAllAttachments;

  /// No description provided for @clearAllAttachmentsConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete every downloaded attachment? Your mail is untouched, but attachments will need downloading again.'**
  String get clearAllAttachmentsConfirm;

  /// No description provided for @clearProfileAttachments.
  ///
  /// In en, this message translates to:
  /// **'Clear this instance\'s attachments'**
  String get clearProfileAttachments;

  /// No description provided for @clearProfileAttachmentsConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete all attachments downloaded for \"{name}\"?'**
  String clearProfileAttachmentsConfirm(String name);

  /// No description provided for @savedTo.
  ///
  /// In en, this message translates to:
  /// **'Saved to {path}'**
  String savedTo(String path);

  /// No description provided for @openFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t open — no app on this system handles this file type'**
  String get openFailed;

  /// No description provided for @shareUnavailable.
  ///
  /// In en, this message translates to:
  /// **'No share sheet on this platform; try \"Save as\"'**
  String get shareUnavailable;

  /// No description provided for @previewUnsupported.
  ///
  /// In en, this message translates to:
  /// **'This format can\'t be previewed in-app; download it and open it with another app'**
  String get previewUnsupported;

  /// No description provided for @viewerSource.
  ///
  /// In en, this message translates to:
  /// **'Source'**
  String get viewerSource;

  /// text viewer: switch a .md attachment back to formatted rendering
  ///
  /// In en, this message translates to:
  /// **'Rendered'**
  String get viewerRendered;

  /// text viewer: footer note when there is more content than the preview cap allows
  ///
  /// In en, this message translates to:
  /// **'Only the first {chars} characters are shown'**
  String viewerTruncated(int chars);

  /// text viewer: footer note when the text had to be decoded with a lossy fallback
  ///
  /// In en, this message translates to:
  /// **'Decoded as {encoding}; some characters may show as ?'**
  String viewerEncodingLossy(String encoding);

  /// text viewer: markdown preview fell back to plain source because MarkdownDoc refused it
  ///
  /// In en, this message translates to:
  /// **'Nested too deeply to render as Markdown — showing the source'**
  String get viewerMarkdownTooDeep;

  /// No description provided for @viewerFileGone.
  ///
  /// In en, this message translates to:
  /// **'The file is no longer on disk'**
  String get viewerFileGone;

  /// docx viewer: footer note about what the simplified renderer leaves out
  ///
  /// In en, this message translates to:
  /// **'Images and layout aren\'t shown in this preview'**
  String get viewerOfficePartial;

  /// office viewer: the bytes aren't an OOXML package at all
  ///
  /// In en, this message translates to:
  /// **'This file isn\'t a Word/Excel/PowerPoint document'**
  String get viewerNotADocument;

  /// office viewer: the package opened but a part is missing or unparseable
  ///
  /// In en, this message translates to:
  /// **'This document is damaged and can\'t be read'**
  String get viewerDocumentBroken;

  /// No description provided for @viewerEmpty.
  ///
  /// In en, this message translates to:
  /// **'(empty file)'**
  String get viewerEmpty;

  /// table viewer (csv / xlsx): footer note when the table was cut off at the parser caps
  ///
  /// In en, this message translates to:
  /// **'Showing the first {rows} rows and {columns} columns'**
  String csvTruncated(int rows, int columns);

  /// csv viewer: footer note naming the separator the sniffer picked
  ///
  /// In en, this message translates to:
  /// **'Delimiter: {delimiter}'**
  String csvDelimiter(String delimiter);

  /// xlsx viewer: footer note when the workbook has more sheets than the parser keeps
  ///
  /// In en, this message translates to:
  /// **'Only the first {count} sheets are shown'**
  String xlsxSheetsTruncated(int count);

  /// xlsx viewer: footer note about what the simplified renderer leaves out
  ///
  /// In en, this message translates to:
  /// **'Number formats are simplified; charts and images aren\'t shown'**
  String get xlsxPartial;

  /// xlsx viewer: a sheet with no rows
  ///
  /// In en, this message translates to:
  /// **'(empty sheet)'**
  String get xlsxSheetEmpty;

  /// pptx viewer: the header of each slide card
  ///
  /// In en, this message translates to:
  /// **'Slide {index} of {total}'**
  String pptxSlideOf(int index, int total);

  /// pptx viewer: footer note about what the text-only renderer leaves out
  ///
  /// In en, this message translates to:
  /// **'Slides are shown as text only; layout, images and animations aren\'t shown'**
  String get pptxPartial;

  /// pptx viewer: footer note when the deck has more slides than the parser keeps
  ///
  /// In en, this message translates to:
  /// **'Only the first {count} slides are shown'**
  String pptxSlidesTruncated(int count);

  /// pptx viewer: a slide whose shapes held no extractable text
  ///
  /// In en, this message translates to:
  /// **'(no text on this slide)'**
  String get pptxSlideEmpty;

  /// No description provided for @play.
  ///
  /// In en, this message translates to:
  /// **'Play'**
  String get play;

  /// No description provided for @pause.
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get pause;

  /// audio viewer: label for the playback speed selector
  ///
  /// In en, this message translates to:
  /// **'Speed'**
  String get playbackRate;

  /// audio viewer: the platform refused to load or play the file (e.g. no gstreamer on Linux)
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t play this file on this system'**
  String get audioFailed;

  /// video viewer: the player failed to initialize for this file
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t play this video'**
  String get videoFailed;

  /// No description provided for @reply.
  ///
  /// In en, this message translates to:
  /// **'Reply'**
  String get reply;

  /// No description provided for @forward.
  ///
  /// In en, this message translates to:
  /// **'Forward'**
  String get forward;

  /// No description provided for @wrote.
  ///
  /// In en, this message translates to:
  /// **'wrote:'**
  String get wrote;

  /// No description provided for @composeFrom.
  ///
  /// In en, this message translates to:
  /// **'From'**
  String get composeFrom;

  /// No description provided for @composeSenderSearch.
  ///
  /// In en, this message translates to:
  /// **'Search sender'**
  String get composeSenderSearch;

  /// No description provided for @composeSenderNoMatch.
  ///
  /// In en, this message translates to:
  /// **'No matching mailbox'**
  String get composeSenderNoMatch;

  /// No description provided for @composeRecipientsHint.
  ///
  /// In en, this message translates to:
  /// **'Type an address, then press Enter'**
  String get composeRecipientsHint;

  /// No description provided for @composeBodyHint.
  ///
  /// In en, this message translates to:
  /// **'Write your message…'**
  String get composeBodyHint;

  /// No description provided for @composeAttach.
  ///
  /// In en, this message translates to:
  /// **'Attach files'**
  String get composeAttach;

  /// No description provided for @composeImageTooLarge.
  ///
  /// In en, this message translates to:
  /// **'Image is too large (5 MB max)'**
  String get composeImageTooLarge;

  /// No description provided for @composeImageTooMany.
  ///
  /// In en, this message translates to:
  /// **'At most 10 images in the message body'**
  String get composeImageTooMany;

  /// No description provided for @composeDropFolderIgnored.
  ///
  /// In en, this message translates to:
  /// **'Folders can\'t be attached'**
  String get composeDropFolderIgnored;

  /// No description provided for @composeAiSelectFirst.
  ///
  /// In en, this message translates to:
  /// **'Select the text you want rewritten first'**
  String get composeAiSelectFirst;

  /// No description provided for @composeAiSelectionHasEmbed.
  ///
  /// In en, this message translates to:
  /// **'The selection contains an image, so it can\'t be rewritten'**
  String get composeAiSelectionHasEmbed;

  /// No description provided for @composeAiSelectionGone.
  ///
  /// In en, this message translates to:
  /// **'The original selection is gone — select the text again'**
  String get composeAiSelectionGone;

  /// No description provided for @composeAttachmentTitle.
  ///
  /// In en, this message translates to:
  /// **'Attachments'**
  String get composeAttachmentTitle;

  /// No description provided for @composeAttachmentCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 attachment} other{{count} attachments}}'**
  String composeAttachmentCount(int count);

  /// No description provided for @composeAttachmentTotal.
  ///
  /// In en, this message translates to:
  /// **'Total {size}'**
  String composeAttachmentTotal(String size);

  /// No description provided for @composeTooManyAttachments.
  ///
  /// In en, this message translates to:
  /// **'At most {count} attachments'**
  String composeTooManyAttachments(int count);

  /// No description provided for @composeTooManyInline.
  ///
  /// In en, this message translates to:
  /// **'At most {count} inline images'**
  String composeTooManyInline(int count);

  /// No description provided for @composeTooLarge.
  ///
  /// In en, this message translates to:
  /// **'Attachments exceed the limit ({limit})'**
  String composeTooLarge(String limit);

  /// No description provided for @composeNoRecipient.
  ///
  /// In en, this message translates to:
  /// **'Add at least one recipient'**
  String get composeNoRecipient;

  /// No description provided for @composeBadRecipient.
  ///
  /// In en, this message translates to:
  /// **'Not a valid address: {address}'**
  String composeBadRecipient(String address);

  /// No description provided for @composeEmptyBody.
  ///
  /// In en, this message translates to:
  /// **'The message body can\'t be empty'**
  String get composeEmptyBody;

  /// No description provided for @composeSenderUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Sender address unavailable'**
  String get composeSenderUnavailable;

  /// No description provided for @composeNoMailbox.
  ///
  /// In en, this message translates to:
  /// **'No usable sender mailbox'**
  String get composeNoMailbox;

  /// No description provided for @composeQuotaUnlimited.
  ///
  /// In en, this message translates to:
  /// **'Sending is unlimited'**
  String get composeQuotaUnlimited;

  /// No description provided for @composeQuotaUsed.
  ///
  /// In en, this message translates to:
  /// **'{used} sent'**
  String composeQuotaUsed(int used);

  /// No description provided for @composeQuotaRemaining.
  ///
  /// In en, this message translates to:
  /// **'{remaining} left'**
  String composeQuotaRemaining(int remaining);

  /// No description provided for @composeQuotaDay.
  ///
  /// In en, this message translates to:
  /// **'Today {used}/{limit}'**
  String composeQuotaDay(int used, int limit);

  /// No description provided for @composeQuotaTotal.
  ///
  /// In en, this message translates to:
  /// **'Quota {used}/{limit}'**
  String composeQuotaTotal(int used, int limit);

  /// No description provided for @composeQuotaExhausted.
  ///
  /// In en, this message translates to:
  /// **'Sending quota used up'**
  String get composeQuotaExhausted;

  /// No description provided for @composeQuotaUnknown.
  ///
  /// In en, this message translates to:
  /// **'Quota unknown'**
  String get composeQuotaUnknown;

  /// No description provided for @composeQuotaBanned.
  ///
  /// In en, this message translates to:
  /// **'Your role isn\'t allowed to send'**
  String get composeQuotaBanned;

  /// No description provided for @composeQuotaInternal.
  ///
  /// In en, this message translates to:
  /// **'Internal mailboxes only'**
  String get composeQuotaInternal;

  /// No description provided for @composeInternalOnlyHint.
  ///
  /// In en, this message translates to:
  /// **'Your quota only allows sending to internal mailboxes; external addresses will be rejected by the server'**
  String get composeInternalOnlyHint;

  /// No description provided for @composeRemoveRecipient.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get composeRemoveRecipient;

  /// No description provided for @composeRecentRecipients.
  ///
  /// In en, this message translates to:
  /// **'Recent'**
  String get composeRecentRecipients;

  /// No description provided for @sending.
  ///
  /// In en, this message translates to:
  /// **'Sending…'**
  String get sending;

  /// No description provided for @sendingProgress.
  ///
  /// In en, this message translates to:
  /// **'Sending {percent}%'**
  String sendingProgress(int percent);

  /// No description provided for @sendSuccess.
  ///
  /// In en, this message translates to:
  /// **'Sent'**
  String get sendSuccess;

  /// No description provided for @sendQueued.
  ///
  /// In en, this message translates to:
  /// **'Added to Outbox — it will send once you\'re online'**
  String get sendQueued;

  /// No description provided for @sendQueuedRetry.
  ///
  /// In en, this message translates to:
  /// **'No network — saved to Outbox and will retry automatically'**
  String get sendQueuedRetry;

  /// No description provided for @sendUnknownResult.
  ///
  /// In en, this message translates to:
  /// **'Send result unknown — the server may already have it. Check the Outbox before resending.'**
  String get sendUnknownResult;

  /// No description provided for @sendAttachmentMissing.
  ///
  /// In en, this message translates to:
  /// **'Attachment is no longer on this device: {name}'**
  String sendAttachmentMissing(String name);

  /// No description provided for @sendDraftCorrupted.
  ///
  /// In en, this message translates to:
  /// **'Draft is corrupted and can\'t be resent'**
  String get sendDraftCorrupted;

  /// No description provided for @sendNow.
  ///
  /// In en, this message translates to:
  /// **'Send now'**
  String get sendNow;

  /// No description provided for @sendLater.
  ///
  /// In en, this message translates to:
  /// **'Save to Outbox'**
  String get sendLater;

  /// No description provided for @outbox.
  ///
  /// In en, this message translates to:
  /// **'Outbox'**
  String get outbox;

  /// No description provided for @outboxEmpty.
  ///
  /// In en, this message translates to:
  /// **'Outbox is empty'**
  String get outboxEmpty;

  /// No description provided for @outboxPending.
  ///
  /// In en, this message translates to:
  /// **'Queued'**
  String get outboxPending;

  /// No description provided for @outboxSending.
  ///
  /// In en, this message translates to:
  /// **'Sending'**
  String get outboxSending;

  /// No description provided for @outboxFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed'**
  String get outboxFailed;

  /// No description provided for @outboxAttempts.
  ///
  /// In en, this message translates to:
  /// **'Tried {count} time(s)'**
  String outboxAttempts(int count);

  /// No description provided for @outboxLastError.
  ///
  /// In en, this message translates to:
  /// **'Reason: {error}'**
  String outboxLastError(String error);

  /// No description provided for @outboxUnknownResultHint.
  ///
  /// In en, this message translates to:
  /// **'This message may already have been sent. Confirm the recipient didn\'t get it before resending.'**
  String get outboxUnknownResultHint;

  /// No description provided for @outboxRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get outboxRetry;

  /// No description provided for @outboxDiscard.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get outboxDiscard;

  /// No description provided for @outboxDiscardConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete this unsent message? Its contents will be lost.'**
  String get outboxDiscardConfirm;

  /// No description provided for @draft.
  ///
  /// In en, this message translates to:
  /// **'Draft'**
  String get draft;

  /// No description provided for @draftSaved.
  ///
  /// In en, this message translates to:
  /// **'Draft saved'**
  String get draftSaved;

  /// No description provided for @draftSavedAt.
  ///
  /// In en, this message translates to:
  /// **'Saved {when}'**
  String draftSavedAt(String when);

  /// No description provided for @draftDiscard.
  ///
  /// In en, this message translates to:
  /// **'Discard draft'**
  String get draftDiscard;

  /// No description provided for @draftDiscardConfirm.
  ///
  /// In en, this message translates to:
  /// **'Discard this draft? Its contents will be lost.'**
  String get draftDiscardConfirm;

  /// No description provided for @draftEmpty.
  ///
  /// In en, this message translates to:
  /// **'No drafts yet'**
  String get draftEmpty;

  /// No description provided for @draftsHint.
  ///
  /// In en, this message translates to:
  /// **'Drafts live on this device only — they don\'t sync with the web app'**
  String get draftsHint;

  /// No description provided for @discardChanges.
  ///
  /// In en, this message translates to:
  /// **'Discard these changes?'**
  String get discardChanges;

  /// No description provided for @keepEditing.
  ///
  /// In en, this message translates to:
  /// **'Keep editing'**
  String get keepEditing;

  /// No description provided for @discard.
  ///
  /// In en, this message translates to:
  /// **'Discard'**
  String get discard;

  /// No description provided for @composeFailedStayHint.
  ///
  /// In en, this message translates to:
  /// **'Your message is still in the editor — fix it and try again'**
  String get composeFailedStayHint;

  /// No description provided for @outboxSent.
  ///
  /// In en, this message translates to:
  /// **'Sent'**
  String get outboxSent;

  /// No description provided for @outboxUnknown.
  ///
  /// In en, this message translates to:
  /// **'Result unknown'**
  String get outboxUnknown;

  /// No description provided for @drafts.
  ///
  /// In en, this message translates to:
  /// **'Drafts'**
  String get drafts;

  /// No description provided for @sendSavedToOutbox.
  ///
  /// In en, this message translates to:
  /// **'Saved to Outbox — it will be sent automatically'**
  String get sendSavedToOutbox;

  /// No description provided for @composeLargeAttachmentHint.
  ///
  /// In en, this message translates to:
  /// **'Large attachments are uploaded in chunks — keep the app open until it finishes'**
  String get composeLargeAttachmentHint;

  /// No description provided for @close_.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get close_;

  /// No description provided for @composeCloseTooltip.
  ///
  /// In en, this message translates to:
  /// **'Close (Esc)'**
  String get composeCloseTooltip;

  /// No description provided for @composeQuotedAttached.
  ///
  /// In en, this message translates to:
  /// **'The original message will be quoted below your text'**
  String get composeQuotedAttached;

  /// No description provided for @mailUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Can\'t load the original message'**
  String get mailUnavailable;

  /// No description provided for @outboxFlush.
  ///
  /// In en, this message translates to:
  /// **'Send all now'**
  String get outboxFlush;

  /// No description provided for @outboxHint.
  ///
  /// In en, this message translates to:
  /// **'Messages here are queued on this device and sent one at a time. Retrying sends a real message — the server has no way to tell a duplicate.'**
  String get outboxHint;

  /// No description provided for @outboxAddressed.
  ///
  /// In en, this message translates to:
  /// **'Addressed to {to}'**
  String outboxAddressed(String to);

  /// No description provided for @syncStatusTitle.
  ///
  /// In en, this message translates to:
  /// **'Sync status'**
  String get syncStatusTitle;

  /// No description provided for @syncStateSyncing.
  ///
  /// In en, this message translates to:
  /// **'Syncing…'**
  String get syncStateSyncing;

  /// No description provided for @syncStateWaiting.
  ///
  /// In en, this message translates to:
  /// **'Waiting'**
  String get syncStateWaiting;

  /// No description provided for @syncStateStopped.
  ///
  /// In en, this message translates to:
  /// **'Stopped'**
  String get syncStateStopped;

  /// No description provided for @syncedCount.
  ///
  /// In en, this message translates to:
  /// **'Synced {count}'**
  String syncedCount(int count);

  /// No description provided for @unsyncedCount.
  ///
  /// In en, this message translates to:
  /// **'{count} to sync'**
  String unsyncedCount(int count);

  /// No description provided for @unsyncedUnknown.
  ///
  /// In en, this message translates to:
  /// **'Remaining unknown'**
  String get unsyncedUnknown;

  /// No description provided for @unsyncedUnknownHint.
  ///
  /// In en, this message translates to:
  /// **'The server total is only known after a full page of /email/list, so this is blank on a fresh install.'**
  String get unsyncedUnknownHint;

  /// No description provided for @syncLastSuccess.
  ///
  /// In en, this message translates to:
  /// **'Last success: {time}'**
  String syncLastSuccess(String time);

  /// No description provided for @syncNeverSucceeded.
  ///
  /// In en, this message translates to:
  /// **'No successful sync yet'**
  String get syncNeverSucceeded;

  /// No description provided for @syncFailCount.
  ///
  /// In en, this message translates to:
  /// **'Failed {count} times in a row'**
  String syncFailCount(int count);

  /// No description provided for @bodyNotSynced.
  ///
  /// In en, this message translates to:
  /// **'Body not fetched yet'**
  String get bodyNotSynced;

  /// No description provided for @pendingMore.
  ///
  /// In en, this message translates to:
  /// **'{count} messages not synced yet · tap to load more'**
  String pendingMore(int count);

  /// No description provided for @pendingMorePassive.
  ///
  /// In en, this message translates to:
  /// **'{count} messages not synced yet'**
  String pendingMorePassive(int count);

  /// No description provided for @listLoadingMore.
  ///
  /// In en, this message translates to:
  /// **'Loading…'**
  String get listLoadingMore;

  /// No description provided for @listNoMore.
  ///
  /// In en, this message translates to:
  /// **'No more messages'**
  String get listNoMore;

  /// No description provided for @listAggregateFooter.
  ///
  /// In en, this message translates to:
  /// **'Aggregate view pulls each instance separately — scrolling to the end syncs again'**
  String get listAggregateFooter;

  /// No description provided for @syncNowOne.
  ///
  /// In en, this message translates to:
  /// **'Sync now'**
  String get syncNowOne;

  /// No description provided for @syncNowFailed.
  ///
  /// In en, this message translates to:
  /// **'This instance can\'t sync (not signed in, or the session is gone). Sign in again first.'**
  String get syncNowFailed;

  /// No description provided for @syncStarted.
  ///
  /// In en, this message translates to:
  /// **'Sync started'**
  String get syncStarted;

  /// No description provided for @syncButtonHint.
  ///
  /// In en, this message translates to:
  /// **'Tap to sync now · long-press or right-click for the sync page'**
  String get syncButtonHint;

  /// No description provided for @syncingThisMail.
  ///
  /// In en, this message translates to:
  /// **'Syncing this message…'**
  String get syncingThisMail;

  /// No description provided for @syncBatchBlocked.
  ///
  /// In en, this message translates to:
  /// **'This instance can\'t receive mail right now (not signed in, or the session is gone). Sign in again first.'**
  String get syncBatchBlocked;

  /// No description provided for @pushAutoProvision.
  ///
  /// In en, this message translates to:
  /// **'One-tap setup (deployer)'**
  String get pushAutoProvision;

  /// No description provided for @pushAutoProvisionHint.
  ///
  /// In en, this message translates to:
  /// **'Creates a relay slot for this device using the deployer admin token. The token is used for this request only — it is never saved to prefs, the keychain, or any log.'**
  String get pushAutoProvisionHint;

  /// No description provided for @pushAdminToken.
  ///
  /// In en, this message translates to:
  /// **'Admin token'**
  String get pushAdminToken;

  /// No description provided for @pushAdminTokenHint.
  ///
  /// In en, this message translates to:
  /// **'Shown only on this screen; cleared when you leave'**
  String get pushAdminTokenHint;

  /// No description provided for @pushAutoProvisionDone.
  ///
  /// In en, this message translates to:
  /// **'Provisioned — instance id and pairing code filled in'**
  String get pushAutoProvisionDone;

  /// No description provided for @sendDelay.
  ///
  /// In en, this message translates to:
  /// **'Send delay'**
  String get sendDelay;

  /// No description provided for @sendDelayHint.
  ///
  /// In en, this message translates to:
  /// **'After you tap Send the message waits this long before actually going out — long enough to cancel if you change your mind.'**
  String get sendDelayHint;

  /// No description provided for @sendDelayNone.
  ///
  /// In en, this message translates to:
  /// **'Send immediately'**
  String get sendDelayNone;

  /// No description provided for @sendDelayMinutes.
  ///
  /// In en, this message translates to:
  /// **'{minutes} min'**
  String sendDelayMinutes(int minutes);

  /// No description provided for @queuedNotice.
  ///
  /// In en, this message translates to:
  /// **'Queued — sending in {minutes} min. You can cancel it from the send queue bar.'**
  String queuedNotice(int minutes);

  /// No description provided for @sendQueueTitle.
  ///
  /// In en, this message translates to:
  /// **'Send queue'**
  String get sendQueueTitle;

  /// No description provided for @sendQueueCount.
  ///
  /// In en, this message translates to:
  /// **'{count} queued'**
  String sendQueueCount(int count);

  /// No description provided for @sendQueueIn.
  ///
  /// In en, this message translates to:
  /// **'sending in {seconds}s'**
  String sendQueueIn(int seconds);

  /// No description provided for @sendQueueSendNow.
  ///
  /// In en, this message translates to:
  /// **'Send now'**
  String get sendQueueSendNow;

  /// No description provided for @sendQueueViewAll.
  ///
  /// In en, this message translates to:
  /// **'View all in Outbox'**
  String get sendQueueViewAll;

  /// No description provided for @sendQueueCancelConfirm.
  ///
  /// In en, this message translates to:
  /// **'Cancel this queued message? It will not be sent.'**
  String get sendQueueCancelConfirm;

  /// No description provided for @sendScheduled.
  ///
  /// In en, this message translates to:
  /// **'Sends in {seconds}s'**
  String sendScheduled(int seconds);

  /// No description provided for @sendQueuedFailed.
  ///
  /// In en, this message translates to:
  /// **'Queued failed — the message is still in the editor'**
  String get sendQueuedFailed;

  /// No description provided for @sendScheduledMinutes.
  ///
  /// In en, this message translates to:
  /// **'Sends in {minutes} min'**
  String sendScheduledMinutes(int minutes);

  /// push settings: pushAdminTokenNeeded
  ///
  /// In en, this message translates to:
  /// **'Enter the admin token first'**
  String get pushAdminTokenNeeded;

  /// push settings: pushBuiltInApplied
  ///
  /// In en, this message translates to:
  /// **'Pre-filled from this build; the pairing code is stored in the keychain only.'**
  String get pushBuiltInApplied;

  /// No description provided for @aiTitle.
  ///
  /// In en, this message translates to:
  /// **'AI'**
  String get aiTitle;

  /// No description provided for @aiSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Bring your own key'**
  String get aiSubtitle;

  /// No description provided for @aiPrivacyNotice.
  ///
  /// In en, this message translates to:
  /// **'Text from your message is sent to the provider you configure. The key is stored in this device\'s keychain and never leaves it except in requests to that provider.'**
  String get aiPrivacyNotice;

  /// No description provided for @aiProviderSection.
  ///
  /// In en, this message translates to:
  /// **'Provider'**
  String get aiProviderSection;

  /// No description provided for @aiModelSection.
  ///
  /// In en, this message translates to:
  /// **'Model'**
  String get aiModelSection;

  /// No description provided for @aiModelLabel.
  ///
  /// In en, this message translates to:
  /// **'Model'**
  String get aiModelLabel;

  /// No description provided for @aiModelHint.
  ///
  /// In en, this message translates to:
  /// **'Model name — type it, or use Fetch to pick one'**
  String get aiModelHint;

  /// No description provided for @aiBaseUrlLabel.
  ///
  /// In en, this message translates to:
  /// **'Endpoint URL'**
  String get aiBaseUrlLabel;

  /// No description provided for @aiBaseUrlHint.
  ///
  /// In en, this message translates to:
  /// **'https://api.openai.com/v1'**
  String get aiBaseUrlHint;

  /// No description provided for @aiApiFormatLabel.
  ///
  /// In en, this message translates to:
  /// **'API format'**
  String get aiApiFormatLabel;

  /// No description provided for @aiApiFormatOpenai.
  ///
  /// In en, this message translates to:
  /// **'OpenAI-compatible'**
  String get aiApiFormatOpenai;

  /// No description provided for @aiApiFormatAnthropic.
  ///
  /// In en, this message translates to:
  /// **'Anthropic'**
  String get aiApiFormatAnthropic;

  /// No description provided for @aiApiFormatNewapi.
  ///
  /// In en, this message translates to:
  /// **'New API'**
  String get aiApiFormatNewapi;

  /// No description provided for @aiBaseUrlHintAnthropic.
  ///
  /// In en, this message translates to:
  /// **'https://api.anthropic.com'**
  String get aiBaseUrlHintAnthropic;

  /// No description provided for @aiBaseUrlHintNewapi.
  ///
  /// In en, this message translates to:
  /// **'https://your-gateway-host — with or without /v1'**
  String get aiBaseUrlHintNewapi;

  /// No description provided for @aiBaseUrlInvalid.
  ///
  /// In en, this message translates to:
  /// **'The URL must start with http:// or https://'**
  String get aiBaseUrlInvalid;

  /// No description provided for @aiModelsFetch.
  ///
  /// In en, this message translates to:
  /// **'Fetch'**
  String get aiModelsFetch;

  /// No description provided for @aiModelsFetchNeedKey.
  ///
  /// In en, this message translates to:
  /// **'Save a key first'**
  String get aiModelsFetchNeedKey;

  /// No description provided for @aiModelsFetchNeedUrl.
  ///
  /// In en, this message translates to:
  /// **'Fill in the URL first'**
  String get aiModelsFetchNeedUrl;

  /// No description provided for @aiModelsEmpty.
  ///
  /// In en, this message translates to:
  /// **'This endpoint has no model list — just type the name'**
  String get aiModelsEmpty;

  /// No description provided for @aiModelsFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t fetch: {message}'**
  String aiModelsFailed(String message);

  /// No description provided for @aiTestConnection.
  ///
  /// In en, this message translates to:
  /// **'Test connection'**
  String get aiTestConnection;

  /// No description provided for @aiTestNeedModel.
  ///
  /// In en, this message translates to:
  /// **'A model name is needed to test — fetch one or type it'**
  String get aiTestNeedModel;

  /// No description provided for @aiTestOk.
  ///
  /// In en, this message translates to:
  /// **'Connected — the model returned {chars} characters'**
  String aiTestOk(int chars);

  /// No description provided for @aiTestOkNoText.
  ///
  /// In en, this message translates to:
  /// **'Connected (only reasoning came back, no visible text — normal for a reasoning model; nothing wrong)'**
  String get aiTestOkNoText;

  /// No description provided for @aiTestFailed.
  ///
  /// In en, this message translates to:
  /// **'Connection failed: {message}'**
  String aiTestFailed(String message);

  /// No description provided for @aiKeySection.
  ///
  /// In en, this message translates to:
  /// **'API key'**
  String get aiKeySection;

  /// No description provided for @aiKeyLabel.
  ///
  /// In en, this message translates to:
  /// **'API key'**
  String get aiKeyLabel;

  /// No description provided for @aiKeyStored.
  ///
  /// In en, this message translates to:
  /// **'A key is saved'**
  String get aiKeyStored;

  /// No description provided for @aiKeyNotStored.
  ///
  /// In en, this message translates to:
  /// **'No key saved yet'**
  String get aiKeyNotStored;

  /// No description provided for @aiKeySave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get aiKeySave;

  /// No description provided for @aiKeyPaste.
  ///
  /// In en, this message translates to:
  /// **'Paste'**
  String get aiKeyPaste;

  /// No description provided for @aiKeyPasteEmpty.
  ///
  /// In en, this message translates to:
  /// **'Nothing on the clipboard to paste'**
  String get aiKeyPasteEmpty;

  /// No description provided for @aiKeyClear.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get aiKeyClear;

  /// No description provided for @aiKeySaved.
  ///
  /// In en, this message translates to:
  /// **'Key saved'**
  String get aiKeySaved;

  /// No description provided for @aiKeyCleared.
  ///
  /// In en, this message translates to:
  /// **'Key cleared'**
  String get aiKeyCleared;

  /// No description provided for @aiKeyEmpty.
  ///
  /// In en, this message translates to:
  /// **'Enter a key first'**
  String get aiKeyEmpty;

  /// No description provided for @aiKeyWhitespace.
  ///
  /// In en, this message translates to:
  /// **'The key contains a space or newline — check the paste'**
  String get aiKeyWhitespace;

  /// No description provided for @aiKeyDegraded.
  ///
  /// In en, this message translates to:
  /// **'This device\'s keychain is unavailable, so the key can\'t be stored. The entry above will not survive a restart.'**
  String get aiKeyDegraded;

  /// No description provided for @aiFeaturesSection.
  ///
  /// In en, this message translates to:
  /// **'Features'**
  String get aiFeaturesSection;

  /// No description provided for @aiInlineContinuation.
  ///
  /// In en, this message translates to:
  /// **'Suggest the next sentence as I pause'**
  String get aiInlineContinuation;

  /// No description provided for @aiInlineContinuationHint.
  ///
  /// In en, this message translates to:
  /// **'Costs one call every time you stop typing'**
  String get aiInlineContinuationHint;

  /// No description provided for @aiPreflight.
  ///
  /// In en, this message translates to:
  /// **'Check before sending'**
  String get aiPreflight;

  /// No description provided for @aiPreflightHint.
  ///
  /// In en, this message translates to:
  /// **'Local checks are free; asking the model costs one call'**
  String get aiPreflightHint;

  /// No description provided for @aiSubjectSuggest.
  ///
  /// In en, this message translates to:
  /// **'Suggest a subject line'**
  String get aiSubjectSuggest;

  /// No description provided for @aiSubjectSuggestHint.
  ///
  /// In en, this message translates to:
  /// **'Tap in the subject row to fill one in; an existing subject is used as reference'**
  String get aiSubjectSuggestHint;

  /// No description provided for @aiPolish.
  ///
  /// In en, this message translates to:
  /// **'Polish the message'**
  String get aiPolish;

  /// No description provided for @aiPolishHint.
  ///
  /// In en, this message translates to:
  /// **'Open the sheet from the compose toolbar: pick a tone, add notes, then tap Generate to replace your body (the quote is untouched; undoable)'**
  String get aiPolishHint;

  /// No description provided for @aiPolishTooltip.
  ///
  /// In en, this message translates to:
  /// **'Polish the whole message'**
  String get aiPolishTooltip;

  /// No description provided for @aiPolishNote.
  ///
  /// In en, this message translates to:
  /// **'Only your own text is polished — the quoted message is left exactly as is.'**
  String get aiPolishNote;

  /// No description provided for @aiPolishExtraHint.
  ///
  /// In en, this message translates to:
  /// **'Extra requirements (optional), e.g. keep the terminology, don\'t change how I address them'**
  String get aiPolishExtraHint;

  /// No description provided for @aiPolishGenerate.
  ///
  /// In en, this message translates to:
  /// **'Generate'**
  String get aiPolishGenerate;

  /// No description provided for @aiPolishReplaceAll.
  ///
  /// In en, this message translates to:
  /// **'Replace the body'**
  String get aiPolishReplaceAll;

  /// No description provided for @aiPolishIdle.
  ///
  /// In en, this message translates to:
  /// **'Pick a tone, add notes, then tap Generate.'**
  String get aiPolishIdle;

  /// No description provided for @aiSubjectEmpty.
  ///
  /// In en, this message translates to:
  /// **'Write some body text first — that\'s what the subject is drawn from'**
  String get aiSubjectEmpty;

  /// No description provided for @aiPolishEmpty.
  ///
  /// In en, this message translates to:
  /// **'The body is still empty'**
  String get aiPolishEmpty;

  /// No description provided for @aiPolishFailed.
  ///
  /// In en, this message translates to:
  /// **'Polishing returned nothing — the body is unchanged'**
  String get aiPolishFailed;

  /// No description provided for @aiBudgetSection.
  ///
  /// In en, this message translates to:
  /// **'Usage'**
  String get aiBudgetSection;

  /// No description provided for @aiDailyLimit.
  ///
  /// In en, this message translates to:
  /// **'Daily call limit'**
  String get aiDailyLimit;

  /// No description provided for @aiDailyLimitHint.
  ///
  /// In en, this message translates to:
  /// **'A soft limit — it warns, it never blocks. 0 means unlimited.'**
  String get aiDailyLimitHint;

  /// No description provided for @aiUsedToday.
  ///
  /// In en, this message translates to:
  /// **'Used today: {used}'**
  String aiUsedToday(int used);

  /// No description provided for @aiUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Fill in your key to turn these on'**
  String get aiUnavailable;

  /// sync status panel countdown
  ///
  /// In en, this message translates to:
  /// **'next in {seconds}s'**
  String syncNextIn(int seconds);

  /// home menu: unread only
  ///
  /// In en, this message translates to:
  /// **'Unread'**
  String get unreadMail;

  /// inbox: mailbox filter sheet title / button tooltip
  ///
  /// In en, this message translates to:
  /// **'Filter by mailbox'**
  String get filterByMailbox;

  /// sidebar: disclosure arrow tooltip on the Inbox item
  ///
  /// In en, this message translates to:
  /// **'Show or hide the mailbox list'**
  String get toggleMailboxList;

  /// inbox: mailbox filter sheet subtitle
  ///
  /// In en, this message translates to:
  /// **'Takes effect on tap; at least one stays selected'**
  String get filterByMailboxHint;

  /// inbox: mailbox filter sheet
  ///
  /// In en, this message translates to:
  /// **'Select all'**
  String get selectAll;

  /// inbox: per-mailbox unread in the filter sheet
  ///
  /// In en, this message translates to:
  /// **'{count} unread'**
  String unreadCount(int count);

  /// inbox: filter sheet, the last checkbox cannot be cleared
  ///
  /// In en, this message translates to:
  /// **'At least one mailbox has to stay selected'**
  String get mailboxKeptOne;

  /// sync panel: mail-level stage
  ///
  /// In en, this message translates to:
  /// **'Synced'**
  String get syncStageSynced;

  /// sync panel: mail-level stage
  ///
  /// In en, this message translates to:
  /// **'Syncing'**
  String get syncStageSyncing;

  /// sync panel: mail-level stage
  ///
  /// In en, this message translates to:
  /// **'Pending'**
  String get syncStagePending;

  /// sync panel: pending reason
  ///
  /// In en, this message translates to:
  /// **'No body'**
  String get syncStagePendingBody;

  /// sync panel: pending reason
  ///
  /// In en, this message translates to:
  /// **'No attachment'**
  String get syncStagePendingAttachment;

  /// sync panel: run every instance now
  ///
  /// In en, this message translates to:
  /// **'Sync everything now'**
  String get syncAllNow;

  /// home menu: outbox entry subtitle when the badge is 0
  ///
  /// In en, this message translates to:
  /// **'Nothing waiting to be sent'**
  String get outboxPendingZero;

  /// sync panel: empty state of the pending tab
  ///
  /// In en, this message translates to:
  /// **'Nothing left to sync'**
  String get syncPanelPendingEmpty;

  /// bottom nav / home screen title for the mail branch
  ///
  /// In en, this message translates to:
  /// **'Mail'**
  String get mailTab;

  /// home screen subtitle: how many instances are logged in
  ///
  /// In en, this message translates to:
  /// **'{count} instances'**
  String instanceCount(int count);

  /// list header subtitle when nothing is filtered
  ///
  /// In en, this message translates to:
  /// **'All instances · all mailboxes'**
  String get allInstancesAllMailboxes;

  /// list header subtitle when several mailboxes are selected
  ///
  /// In en, this message translates to:
  /// **'{count} mailboxes selected'**
  String mailboxCountSelected(int count);

  /// sync panel: empty state of the synced tab
  ///
  /// In en, this message translates to:
  /// **'Nothing synced yet'**
  String get syncPanelSyncedEmpty;

  /// sync panel row: attachment download progress
  ///
  /// In en, this message translates to:
  /// **'{done}/{total} attachments'**
  String attachmentProgress(int done, int total);

  /// sync panel: result of the batch sync button
  ///
  /// In en, this message translates to:
  /// **'Synced {bodies} bodies and {attachments} attachments'**
  String syncBatchDone(int bodies, int attachments);

  /// sync panel: batch sync ran but the pending list was empty
  ///
  /// In en, this message translates to:
  /// **'Nothing left to sync'**
  String get syncBatchNothing;

  /// sync panel: batch sync hit its per-run limit
  ///
  /// In en, this message translates to:
  /// **'Synced {mails}; more are waiting (tap again to continue)'**
  String syncBatchMore(int mails);

  /// mail list row menu / detail top bar: AI suggestion entry
  ///
  /// In en, this message translates to:
  /// **'AI suggestions'**
  String get aiSuggest;

  /// AI settings: the mail-suggest switch subtitle
  ///
  /// In en, this message translates to:
  /// **'Read a message and see what\'s worth doing — tap one to do it (reply / forward / remind / delete…)'**
  String get aiSuggestHint;

  /// suggestion panel title
  ///
  /// In en, this message translates to:
  /// **'AI suggestions'**
  String get aiSuggestPanelTitle;

  /// suggestion panel header line 1
  ///
  /// In en, this message translates to:
  /// **'Read: subject, sender, body ({chars} chars)'**
  String aiSuggestReading(int chars);

  /// suggestion panel header: attachment count segment
  ///
  /// In en, this message translates to:
  /// **'+ {count} attachment names'**
  String aiSuggestAttachments(int count);

  /// suggestion panel header: quoted text was trimmed
  ///
  /// In en, this message translates to:
  /// **'quoted text trimmed · {chars} chars original'**
  String aiSuggestQuotedDropped(int chars);

  /// suggestion panel header: body hit the length cap
  ///
  /// In en, this message translates to:
  /// **'Body too long — using the first {chars} chars'**
  String aiSuggestTruncated(int chars);

  /// suggestion panel: fetching the full body
  ///
  /// In en, this message translates to:
  /// **'Fetching the full message…'**
  String get aiSuggestFetchingBody;

  /// suggestion panel: analysis in flight
  ///
  /// In en, this message translates to:
  /// **'Analyzing…'**
  String get aiSuggestAnalyzing;

  /// suggestion panel: re-run the analysis
  ///
  /// In en, this message translates to:
  /// **'Re-analyze'**
  String get aiSuggestReanalyze;

  /// suggestion panel: retry after a failure
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get aiSuggestRetry;

  /// suggestion panel: could not parse the model reply
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t read a suggestion out of the model\'s reply:'**
  String get aiSuggestParseFailed;

  /// suggestion panel: badge on the first (most recommended) item
  ///
  /// In en, this message translates to:
  /// **'Top pick'**
  String get aiSuggestTopPick;

  /// action label: reply
  ///
  /// In en, this message translates to:
  /// **'Reply'**
  String get aiSuggestActionReply;

  /// action label: forward
  ///
  /// In en, this message translates to:
  /// **'Forward'**
  String get aiSuggestActionForward;

  /// action label: delete
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get aiSuggestActionDelete;

  /// action label: mark as read
  ///
  /// In en, this message translates to:
  /// **'Mark as read'**
  String get aiSuggestActionMarkRead;

  /// action label: mark as unread
  ///
  /// In en, this message translates to:
  /// **'Mark as unread'**
  String get aiSuggestActionMarkUnread;

  /// action label: star
  ///
  /// In en, this message translates to:
  /// **'Add star'**
  String get aiSuggestActionStar;

  /// action label: unstar
  ///
  /// In en, this message translates to:
  /// **'Remove star'**
  String get aiSuggestActionUnstar;

  /// action label: remind me later
  ///
  /// In en, this message translates to:
  /// **'Remind me later'**
  String get aiSuggestActionRemind;

  /// action label: nothing to do
  ///
  /// In en, this message translates to:
  /// **'Nothing to do'**
  String get aiSuggestActionNone;

  /// delete confirmation dialog body
  ///
  /// In en, this message translates to:
  /// **'Delete \"{subject}\"?'**
  String aiSuggestDeleteConfirm(String subject);

  /// reminder time picker title
  ///
  /// In en, this message translates to:
  /// **'When should we remind you?'**
  String get remindTitle;

  /// reminder quick option: today 18:00 (label only; the time itself is computed)
  ///
  /// In en, this message translates to:
  /// **'Today 6:00 PM'**
  String get remindToday;

  /// reminder quick option: tomorrow 9:00
  ///
  /// In en, this message translates to:
  /// **'Tomorrow 9:00 AM'**
  String get remindTomorrow;

  /// reminder quick option: next Monday 9:00
  ///
  /// In en, this message translates to:
  /// **'Next Monday 9:00 AM'**
  String get remindNextMonday;

  /// reminder quick option: custom date/time
  ///
  /// In en, this message translates to:
  /// **'Custom…'**
  String get remindCustom;

  /// reminder: the chosen time is in the past
  ///
  /// In en, this message translates to:
  /// **'That time has already passed'**
  String get remindPast;

  /// snack bar after a reminder is scheduled
  ///
  /// In en, this message translates to:
  /// **'We\'ll remind you at {time}'**
  String remindScheduled(String time);

  /// multi-select: title of the selection pane / bottom bar
  ///
  /// In en, this message translates to:
  /// **'{count} selected'**
  String selectedCount(int count);

  /// multi-select: a row-menu / pane action applied to the whole selection
  ///
  /// In en, this message translates to:
  /// **'{action} ({count} selected)'**
  String selectionActionWithCount(String action, int count);

  /// multi-select: leave multi-select mode
  ///
  /// In en, this message translates to:
  /// **'Clear selection'**
  String get selectionClear;

  /// multi-select: delete confirmation body (server-side delete is permanent)
  ///
  /// In en, this message translates to:
  /// **'Delete the {count} selected messages? This cannot be undone.'**
  String selectionDeleteConfirm(int count);

  /// multi-select statistics: how many of the selection are unread
  ///
  /// In en, this message translates to:
  /// **'{count} unread'**
  String selectionUnread(int count);

  /// multi-select statistics: how many of the selection carry attachments
  ///
  /// In en, this message translates to:
  /// **'{count} with attachments'**
  String selectionWithAttachments(int count);

  /// multi-select statistics: the span of dates covered by the selection
  ///
  /// In en, this message translates to:
  /// **'{from} – {to}'**
  String selectionTimeRange(String from, String to);

  /// multi-select: select every row currently loaded in the list
  ///
  /// In en, this message translates to:
  /// **'Select all ({count} loaded)'**
  String selectionSelectAll(int count);

  /// multi-select: none of the selected messages resolve to a row in the current list any more
  ///
  /// In en, this message translates to:
  /// **'The selected messages are no longer in this list'**
  String get selectionStale;

  /// settings: page title for the mailbox category (the rail uses the shorter `mailbox`)
  ///
  /// In en, this message translates to:
  /// **'Mailbox management'**
  String get mailboxTitle;

  /// settings > mailboxes: the add button on each instance group header
  ///
  /// In en, this message translates to:
  /// **'Add mailbox'**
  String get mailboxAdd;

  /// settings > mailboxes: title of the add-mailbox dialog
  ///
  /// In en, this message translates to:
  /// **'Add mailbox'**
  String get mailboxAddTitle;

  /// settings > mailboxes: label of the single-field fallback when domainList is unavailable
  ///
  /// In en, this message translates to:
  /// **'Full email address'**
  String get mailboxAddFullAddress;

  /// settings > mailboxes: hint under the full-address fallback field
  ///
  /// In en, this message translates to:
  /// **'Domain list unavailable — please type the full address'**
  String get mailboxDomainUnavailable;

  /// settings > mailboxes: shown instead of the add button when addEmail/manyEmail is off server-side
  ///
  /// In en, this message translates to:
  /// **'This instance has adding disabled'**
  String get mailboxAddDisabledByServer;

  /// settings > mailboxes: shown instead of the add button when perm account:add is missing
  ///
  /// In en, this message translates to:
  /// **'This account may not add mailboxes — ask your administrator'**
  String get mailboxAddDenied;

  /// settings > mailboxes: shown instead of the add button when the instance has no token
  ///
  /// In en, this message translates to:
  /// **'Sign in to this instance first'**
  String get mailboxNeedLogin;

  /// settings > mailboxes: banner shown when the server needs a Turnstile token
  ///
  /// In en, this message translates to:
  /// **'This instance requires a human check — add it on the web'**
  String get mailboxAddVerifyRequired;

  /// settings > mailboxes: the button that opens the instance in a browser (Turnstile fallback)
  ///
  /// In en, this message translates to:
  /// **'Add on the web'**
  String get mailboxOpenWeb;

  /// settings > mailboxes: destructive-delete confirmation, the address is spelled out
  ///
  /// In en, this message translates to:
  /// **'Delete “{email}”? Its mail will be permanently deleted too — this cannot be undone.'**
  String mailboxRemoveConfirm(String email);

  /// settings > mailboxes: snackbar after a mailbox was deleted
  ///
  /// In en, this message translates to:
  /// **'Deleted {email}'**
  String mailboxRemoved(String email);

  /// settings > mailboxes: snackbar after a mailbox was created
  ///
  /// In en, this message translates to:
  /// **'Added {email}'**
  String mailboxAdded(String email);

  /// settings > mailboxes: row menu item (email:send perm)
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get mailboxRename;

  /// settings > mailboxes: row menu item; server puts it right after the primary mailbox
  ///
  /// In en, this message translates to:
  /// **'Pin to top'**
  String get mailboxPin;

  /// settings > mailboxes: badge on the primary mailbox row (cannot be deleted or pinned)
  ///
  /// In en, this message translates to:
  /// **'Primary'**
  String get mailboxPrimaryBadge;

  /// settings > mailboxes: local pre-check, mirrors the server minEmailPrefix rule
  ///
  /// In en, this message translates to:
  /// **'Prefix must be at least {n} characters'**
  String mailboxPrefixTooShort(int n);

  /// settings > mailboxes: local pre-check, mirrors the server isEmail regex
  ///
  /// In en, this message translates to:
  /// **'That is not a valid email address'**
  String get mailboxInvalidAddress;

  /// settings > mailboxes: rename dialog; the server does NOT reject an empty name, so the client must
  ///
  /// In en, this message translates to:
  /// **'Name cannot be empty'**
  String get mailboxEmptyName;

  /// settings > mailboxes: rename dialog; mirrors the server usernameLengthLimit of 30
  ///
  /// In en, this message translates to:
  /// **'Name must be at most 30 characters'**
  String get mailboxNameTooLong;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
