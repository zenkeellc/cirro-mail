// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Cirro Mail';

  @override
  String get servers => 'Servers';

  @override
  String get addServer => 'Add server';

  @override
  String get addInstance => 'Add instance';

  @override
  String get serverAddress => 'Server address';

  @override
  String get serverAddressHint => 'https://example.com/api';

  @override
  String get testConnection => 'Test connection';

  @override
  String get testing => 'Testing…';

  @override
  String connectedTo(String title) {
    return 'Connected to $title';
  }

  @override
  String get addAndSignIn => 'Add and sign in';

  @override
  String get login => 'Sign in';

  @override
  String get logout => 'Sign out';

  @override
  String get logoutKeepServer => 'Sign out (keep server)';

  @override
  String get removeServer => 'Remove server';

  @override
  String removeServerConfirm(String name) {
    return 'Remove \"$name\" and its cached mail?';
  }

  @override
  String get email => 'Email';

  @override
  String get password => 'Password';

  @override
  String get signingIn => 'Signing in…';

  @override
  String get nickname => 'Nickname';

  @override
  String get save => 'Save';

  @override
  String get cancel => 'Cancel';

  @override
  String get delete => 'Delete';

  @override
  String get confirm => 'Confirm';

  @override
  String get retry => 'Retry';

  @override
  String get copied => 'Copied';

  @override
  String get copy => 'Copy';

  @override
  String get all => 'All';

  @override
  String get aggregateInbox => 'All mail';

  @override
  String get markAllRead => 'Mark all read';

  @override
  String get markRead => 'Mark read';

  @override
  String get markUnread => 'Mark unread';

  @override
  String get refresh => 'Refresh';

  @override
  String get settings => 'Settings';

  @override
  String get diagnostics => 'Diagnostics';

  @override
  String get inbox => 'Inbox';

  @override
  String get sent => 'Sent';

  @override
  String get starred => 'Starred';

  @override
  String get star => 'Star';

  @override
  String get unstar => 'Unstar';

  @override
  String get newMail => 'New mail';

  @override
  String newMailSummary(String name, int count) {
    return '$name: $count new messages';
  }

  @override
  String get notifyBanner => 'In-app banner';

  @override
  String get notifyBannerHint =>
      'Turning this off still fetches mail (the list keeps updating) — it just stops the pop-ups.';

  @override
  String get pushTitle => 'Background push (FCM)';

  @override
  String get pushShort => 'Push';

  @override
  String get pushHint =>
      'When the app is backgrounded or frozen by the system, a relay delivers new-mail alerts. You can skip this — you just won\'t be alerted in the background.';

  @override
  String get pushRelayUrl => 'Relay URL';

  @override
  String get pushRelayUrlHint =>
      'Your self-hosted mail-push worker, e.g. https://push.example.com';

  @override
  String get pushInstanceId => 'Instance slot id';

  @override
  String get pushInstanceIdHint =>
      'The id your deployment\'s /admin/instances created';

  @override
  String get pushPairingCode => 'Pairing code';

  @override
  String get pushPairingCodeHint =>
      'Shown once when the slot was created; rotate if you lost it';

  @override
  String get pushDeviceId => 'Device id';

  @override
  String get pushDeviceIdHint =>
      'Generated automatically on this device and tied to the slot id — you never need to edit it. Handy for support: it\'s what the relay knows this device as.';

  @override
  String get pushEnable => 'Enable background push';

  @override
  String get pushEnabledHint =>
      'Affects background alerts only — foreground sync, polling and in-app banners are unaffected.';

  @override
  String get pushRegister => 'Register this device';

  @override
  String get pushUnregister => 'Unsubscribe';

  @override
  String get pushTestOk => 'Relay reachable';

  @override
  String get pushRegistrations => 'Mailboxes on the relay';

  @override
  String get pushRegistrationsEmpty =>
      'This device isn\'t registered for any mailbox yet';

  @override
  String get pushUnsupported =>
      'No FCM implementation on this platform (only Linux / Windows — those rely on the app polling while it runs).';

  @override
  String get pushNotConfigured =>
      'Relay settings aren\'t filled in — mail arrives only while the app is running.';

  @override
  String get pushNoFirebaseConfig =>
      'This build has no Firebase config file (google-services.json / GoogleService-Info.plist), so FCM is unavailable. Create a Firebase project and rebuild.';

  @override
  String get pushRelayFcmMissing =>
      'The relay has no FCM service account configured, so nothing can be delivered.';

  @override
  String get pushWebhookHint =>
      'Paste these two into the \"Webhook push\" settings of *your* cloud-mail instance, then turn that switch on. This step can only be done by you — the relay doesn\'t know the instance\'s login system and can\'t do it for you.';

  @override
  String get pushWebhookUrl => 'Webhook URL';

  @override
  String get pushWebhookSecret => 'Webhook secret';

  @override
  String get pushWebhookNoSecret => 'No pairing code yet, so no secret to show';

  @override
  String get pushCopy => 'Copy';

  @override
  String get pushCopied => 'Copied';

  @override
  String get pushChecking => 'Checking…';

  @override
  String get pushSelfCheckOk => 'Pairing code and URL both check out';

  @override
  String get pushSelfCheckSecretBad =>
      'Wrong pairing code — this slot\'s secret was rotated; get a fresh one';

  @override
  String get pushSelfCheckUrlBad =>
      'Wrong URL — it must include the /<slot>/webhook part';

  @override
  String get pushSelfCheckNoEventYet =>
      'Config looks fine, but this slot has never actually received an event — remember to save it in the instance admin and turn the switch on.';

  @override
  String pushSelfCheckGotEvent(String time) {
    return 'Last webhook received: $time';
  }

  @override
  String get pushNeedLoginFirst =>
      'Fill in the pairing code and slot id above first, so the self-check knows what to ask about.';

  @override
  String get pushLimits => 'Limits (worth knowing up front)';

  @override
  String get pushLimit1 =>
      'External mail only: mail sent inside the instance, and mail from other clients, never triggers a push — only polling sees those.';

  @override
  String get pushLimit2 =>
      'If the instance is set to rule-based receiving, the webhook never fires.';

  @override
  String get pushLimit3 =>
      'The push carries metadata only (sender / subject / code); the app still fetches the body from the instance with its own token.';

  @override
  String get pushLimit4 =>
      'The relay can see the metadata of every instance\'s mail — if you self-host it, that\'s you.';

  @override
  String get pushAdvanced => 'Advanced';

  @override
  String pushPageStepOf(int index, int total) {
    return 'Step $index of $total';
  }

  @override
  String get pushPageBack => 'Back';

  @override
  String get pushPageNext => 'Next';

  @override
  String get pushPageDone => 'Done';

  @override
  String get pushPageRecheck => 'Re-check status';

  @override
  String get pushPageStatusTitle => 'Is push working right now?';

  @override
  String get pushPageStatusBody =>
      'Three things are independent: this platform, the three relay values, and whether this device is registered. If any one of them is missing, nothing reaches you while the app is closed.';

  @override
  String get pushPageStatusPlatform => 'This platform supports FCM';

  @override
  String get pushPageStatusOk => 'Looks good';

  @override
  String get pushPageStatusConfigured => 'The three relay values are filled in';

  @override
  String pushPageStatusRegisteredCount(int count) {
    return 'Registered: $count';
  }

  @override
  String get pushPageStatusOff =>
      'The master switch is off — none of the steps below will happen.';

  @override
  String get pushPageStatusGo => 'Turn the switch on';

  @override
  String get pushPageValuesTitle => 'Enter the three values';

  @override
  String get pushPageValuesBody =>
      'All three come from the relay: the URL is the worker\'s domain, the slot id is the slot it created for you, and the pairing code is shown once, at creation.';

  @override
  String get pushPageValuesSave => 'Save these three values';

  @override
  String get pushPageValuesSaved => 'Saved';

  @override
  String get pushPageValuesKeep =>
      'The pairing code is shown once, when a slot is created; neither backend can read it back. If you lose it, rotate the slot.';

  @override
  String get pushPageValuesProvision => 'I run the relay — create a new slot';

  @override
  String get pushPageEnableTitle => 'Turn on background push';

  @override
  String get pushPageEnableBody =>
      'This switch only governs alerts while the app isn\'t in the foreground — foreground sync, polling and in-app banners are unaffected.';

  @override
  String get pushPageEnableOff =>
      'Turning the switch off also unsubscribes, so the relay stops pushing to this device.';

  @override
  String get pushPageEnrollTitle => 'Register this device';

  @override
  String get pushPageEnrollBody =>
      'Binds each mailbox to this device\'s FCM token. It also runs automatically on launch, so this step is mainly here to confirm it worked.';

  @override
  String get pushPageEnrollPermission =>
      'The first time you register, the system asks for notification permission — that prompt is this step.';

  @override
  String get pushPageEnrollBlocked =>
      'Fill in the three values on step 2 and turn the switch on in step 3 first.';

  @override
  String get pushPageEnrollUnsubHint =>
      'Unsubscribe removes every registration for this device on the relay — no more pushes after that.';

  @override
  String get pushPageWebhookTitle =>
      'Turn on Webhook push in your instance\'s admin';

  @override
  String get pushPageWebhookBody =>
      'This is the one step that must be done on another site, and the one people most often forget.';

  @override
  String get pushPageWebhookAdminAsk => 'Do you run this cloud-mail instance?';

  @override
  String get pushPageWebhookAdminYes => 'Yes — I\'ll fill it in';

  @override
  String get pushPageWebhookAdminNo => 'No — send it to the admin';

  @override
  String get pushPageWebhookAdminOtherHint =>
      'Copy the message below and send it to whoever runs your instance.';

  @override
  String get pushPageWebhookRelayCopy => 'Copy a message to send';

  @override
  String pushPageWebhookRelayMessage(String url, String code) {
    return 'Please open \"Webhook push\" in the cloud-mail instance admin, fill in the URL $url and the secret $code, and turn that switch on. New mail can only reach my phone after that.';
  }

  @override
  String get pushPageWebhookStatus0 =>
      'Note: that switch is stored as webhookStatus, and 0 means enabled — the field name reads backwards, so it is the first suspect when nothing arrives.';

  @override
  String get pushPageWebhookConfirm =>
      'I\'ve filled in both values in the instance admin, and turned Webhook push on';

  @override
  String get pushPageWebhookConfirmed =>
      'Confirmed. Change the URL or the pairing code above and this step needs confirming again.';

  @override
  String get pushPageWebhookUnconfirmed =>
      'That part happens on another site, so the app can\'t see it — you have to tick the box yourself, otherwise this step keeps reading as not done.';

  @override
  String pushPageWebhookEvidence(String time) {
    return 'The relay has already received a webhook ($time) — this step works, no confirmation needed.';
  }

  @override
  String pushPageCheckRememberedAt(String time) {
    return 'The last check passed ($time) and nothing above has changed — it stays remembered.';
  }

  @override
  String get pushPageCheckNever =>
      'Not checked yet. Tap the button above once; the result is remembered.';

  @override
  String pushRefreshed(int count) {
    return 'Refreshed: the relay has $count mailbox(es)';
  }

  @override
  String get pushRefreshedEmpty =>
      'Refreshed: the relay has no mailboxes registered yet';

  @override
  String get pushRegistering => 'Registering…';

  @override
  String get pushUnregistering => 'Unsubscribing…';

  @override
  String get pushRefreshing => 'Refreshing…';

  @override
  String get pushPageCheckTitle => 'Check the whole chain';

  @override
  String get pushPageCheckBody =>
      'One pass answers four things: can the relay be reached, does it have FCM, is this pairing code right, and is the URL saved in your instance correct.';

  @override
  String get pushPageCheckAction => 'Check this chain';

  @override
  String get pushPageCheckStale =>
      'You changed the values above — run the check again for a fresh result.';

  @override
  String get pushPageCheckFcmOk => 'The relay has an FCM service account';

  @override
  String get pushPageNotesTitle => 'A few things worth knowing first';

  @override
  String get pushPageNotesBody =>
      'Background push is deliberately narrow: it covers external mail only, and everything else still arrives through polling.';

  @override
  String get pushPageNotesTurnOff => 'How to turn it off';

  @override
  String get pushPageNotesTurnOffBody =>
      'Go back to step 3 and turn the switch off; the app unsubscribes for you.';

  @override
  String get pushPageNotesSwitchSlot => 'If you switch to another slot';

  @override
  String get pushPageNotesSwitchSlotBody =>
      'The app unsubscribes from the old slot automatically — there is nothing to clean up by hand.';

  @override
  String get pushPageDocsHint =>
      'Full commands and troubleshooting are in docs/push-setup.md in the repository.';

  @override
  String get compose => 'Compose';

  @override
  String get composeSectionSignatures => 'Signatures';

  @override
  String composeSignatureFor(String email) {
    return 'Signature for $email';
  }

  @override
  String get composePhrases => 'Common phrases';

  @override
  String composePhrasesFor(String email) {
    return 'Common phrases for $email';
  }

  @override
  String get composePhraseName => 'Name';

  @override
  String get composePhraseText => 'Text';

  @override
  String get composeSignatureEmpty => 'No mailbox yet — add an instance first';

  @override
  String get composeSnippetsHint =>
      'Signatures and phrases are shared across instances by email address';

  @override
  String get noMailbox => 'No mailbox available';

  @override
  String get needAccountPerm =>
      'This account can\'t list mailboxes (missing \"account:query\" permission); showing the primary mailbox only.';

  @override
  String get emptyList => 'No mail';

  @override
  String get loadFailed => 'Load failed';

  @override
  String get attachmentUnavailable => 'Attachment unavailable';

  @override
  String get serverUnreachable => 'Server unreachable';

  @override
  String get sessionExpired => 'Session expired, sign in again';

  @override
  String get sessionExpiredHint =>
      'The sign-in may have been replaced by another device (one account allows 10 sessions).';

  @override
  String get needsLogin => 'Needs sign-in';

  @override
  String get syncNow => 'Sync now';

  @override
  String get close => 'Close';

  @override
  String get switchMailbox => 'Switch mailbox';

  @override
  String get pickMail => 'Pick a mail';

  @override
  String get syncing => 'Syncing';

  @override
  String lastSync(String time) {
    return 'Last sync $time';
  }

  @override
  String get pollInterval => 'Check for mail every';

  @override
  String get pollIntervalHint =>
      'How often new mail is fetched (1 minute – 1 hour). Shorter is more timely and uses more battery.';

  @override
  String minutesCount(int minutes) {
    return '$minutes min';
  }

  @override
  String get notifications => 'Notifications';

  @override
  String get notifyEnabledHint =>
      'Turning this off stops polling and new-mail alerts; mail you already received stays readable.';

  @override
  String get clearCache => 'Clear cache';

  @override
  String get unnamed => '(unnamed)';

  @override
  String get unknown => 'Unknown';

  @override
  String get noSubject => '(no subject)';

  @override
  String get pageNotFound => 'Page not found';

  @override
  String cannotOpen(String uri) {
    return 'Can\'t open: $uri';
  }

  @override
  String get backToInbox => 'Back to inbox';

  @override
  String get startupFailed => 'Startup failed';

  @override
  String get startupFailedHint =>
      'Local data couldn\'t be opened, so the app can\'t continue. The reason is below.';

  @override
  String get keystoreDegraded =>
      'The system keystore is unavailable; sign-in state will only live in memory and must be entered again after a restart.';

  @override
  String get removeServerLostDrafts =>
      'If it keeps failing, remove the instance and add it again (unsent drafts will be lost).';

  @override
  String get instances => 'Instances';

  @override
  String get noInstances => 'No instances yet';

  @override
  String get addFirstInstance => 'Add your first instance';

  @override
  String get editInstance => 'Edit instance';

  @override
  String get edit => 'Edit';

  @override
  String get instanceName => 'Instance name';

  @override
  String get connectionOk => 'Connection OK';

  @override
  String get connectionFailed => 'Connection failed';

  @override
  String get checkAddress => 'Check the server address and your network.';

  @override
  String get serverAddressRequired => 'Enter the server address';

  @override
  String get emailRequired => 'Enter your email';

  @override
  String get passwordRequired => 'Enter your password';

  @override
  String get loginFailed => 'Sign-in failed';

  @override
  String signedInAs(String email) {
    return 'Signed in as $email';
  }

  @override
  String get instanceNeedsLoginHint =>
      'The session for this instance expired. Sign in again — other instances are unaffected.';

  @override
  String get noInstancesLoggedIn => 'No instance is signed in';

  @override
  String get polling => 'Polling';

  @override
  String get appearance => 'Appearance';

  @override
  String get theme => 'Theme';

  @override
  String get themeSystem => 'System';

  @override
  String get themeLight => 'Light';

  @override
  String get themeDark => 'Dark';

  @override
  String get language => 'Language';

  @override
  String get languageSystem => 'Follow system';

  @override
  String get about => 'About';

  @override
  String get version => 'Version';

  @override
  String get capabilities => 'Capabilities';

  @override
  String get syncStatus => 'Sync status';

  @override
  String get intervalLabel => 'Interval';

  @override
  String lastSyncAt(String time) {
    return 'Last sync: $time';
  }

  @override
  String get consecutiveFailures => 'Consecutive failures';

  @override
  String get cursor => 'Cursor';

  @override
  String get endpointSelfCheck => 'Endpoint self-check';

  @override
  String get rawEnvelope => 'Raw response';

  @override
  String get notFoundInWindow =>
      'This message isn\'t in the loaded window yet.';

  @override
  String get openExternally => 'Open in browser';

  @override
  String get probeNotRun => 'Not probed';

  @override
  String get send => 'Send';

  @override
  String get sendFailed => 'Send failed';

  @override
  String get composeTo => 'To';

  @override
  String get composeSubject => 'Subject';

  @override
  String get composeBody => 'Message';

  @override
  String get removeInstance => 'Remove instance';

  @override
  String get checkingSession => 'Checking session…';

  @override
  String get setAsCurrent => 'Set as current';

  @override
  String setAsCurrentOk(Object name) {
    return 'Now showing $name';
  }

  @override
  String removeInstanceConfirm(Object name) {
    return 'Remove \"$name\" and all of its cached mail?';
  }

  @override
  String signOutConfirm(Object name) {
    return 'Sign out of \"$name\"? Mail that has not been sent will be kept.';
  }

  @override
  String get prefetchTitle => 'Prefetch full bodies';

  @override
  String get prefetchHint =>
      'Pulls full=1 while paging so messages open instantly; turn off to save data';

  @override
  String get selfCheckHint =>
      'Tap to hit the key endpoints once and see what the server actually returns';

  @override
  String get selfCheckLoginFirst =>
      'Sign in first — these endpoints would only return 401';

  @override
  String get noMailboxCache => 'No mailbox cache yet';

  @override
  String get noScheduler =>
      'Scheduler not running — no instance is signed in, or polling is paused';

  @override
  String get allMailboxes => 'All mailboxes';

  @override
  String get lastSyncedAt => 'Last sync';

  @override
  String get domainList => 'Domains';

  @override
  String get siteConfig => 'Site config';

  @override
  String get probedAt => 'Probed at';

  @override
  String get fieldTitle => 'title';

  @override
  String get fieldR2Domain => 'r2Domain';

  @override
  String get missingGoesOssApi => 'missing (using /api/oss/)';

  @override
  String get mailbox => 'Mailboxes';

  @override
  String get toggleInstanceMailboxList =>
      'Show or hide this instance\'s mailboxes';

  @override
  String mailboxCountsLabel(int unread, int total) {
    return '$total messages, $unread unread';
  }

  @override
  String get nicknameHint => 'Falls back to the site title or your email';

  @override
  String get download => 'Download';

  @override
  String get downloading => 'Downloading…';

  @override
  String get openWith => 'Open with another app';

  @override
  String get share => 'Share';

  @override
  String get saveAs => 'Save as';

  @override
  String get preview => 'Preview';

  @override
  String get attachmentDownloaded => 'Downloaded';

  @override
  String get attachmentDeleted => 'Local copy deleted';

  @override
  String get attachmentCache => 'Attachment cache';

  @override
  String get attachmentCacheHint =>
      'Downloaded attachments are kept here for offline use';

  @override
  String get cacheEmpty => 'No attachments downloaded yet';

  @override
  String get pickAttachment => 'Pick an attachment';

  @override
  String cacheUsage(int files, String size) {
    return '$files files · $size';
  }

  @override
  String get clearAllAttachments => 'Clear all attachments';

  @override
  String get clearAllAttachmentsConfirm =>
      'Delete every downloaded attachment? Your mail is untouched, but attachments will need downloading again.';

  @override
  String get clearProfileAttachments => 'Clear this instance\'s attachments';

  @override
  String clearProfileAttachmentsConfirm(String name) {
    return 'Delete all attachments downloaded for \"$name\"?';
  }

  @override
  String savedTo(String path) {
    return 'Saved to $path';
  }

  @override
  String get openFailed =>
      'Couldn\'t open — no app on this system handles this file type';

  @override
  String get shareUnavailable =>
      'No share sheet on this platform; try \"Save as\"';

  @override
  String get previewUnsupported =>
      'This format can\'t be previewed in-app; download it and open it with another app';

  @override
  String get viewerSource => 'Source';

  @override
  String get viewerRendered => 'Rendered';

  @override
  String viewerTruncated(int chars) {
    return 'Only the first $chars characters are shown';
  }

  @override
  String viewerEncodingLossy(String encoding) {
    return 'Decoded as $encoding; some characters may show as ?';
  }

  @override
  String get viewerMarkdownTooDeep =>
      'Nested too deeply to render as Markdown — showing the source';

  @override
  String get viewerFileGone => 'The file is no longer on disk';

  @override
  String get viewerOfficePartial =>
      'Images and layout aren\'t shown in this preview';

  @override
  String get viewerNotADocument =>
      'This file isn\'t a Word/Excel/PowerPoint document';

  @override
  String get viewerDocumentBroken =>
      'This document is damaged and can\'t be read';

  @override
  String get viewerEmpty => '(empty file)';

  @override
  String csvTruncated(int rows, int columns) {
    return 'Showing the first $rows rows and $columns columns';
  }

  @override
  String csvDelimiter(String delimiter) {
    return 'Delimiter: $delimiter';
  }

  @override
  String xlsxSheetsTruncated(int count) {
    return 'Only the first $count sheets are shown';
  }

  @override
  String get xlsxPartial =>
      'Number formats are simplified; charts and images aren\'t shown';

  @override
  String get xlsxSheetEmpty => '(empty sheet)';

  @override
  String pptxSlideOf(int index, int total) {
    return 'Slide $index of $total';
  }

  @override
  String get pptxPartial =>
      'Slides are shown as text only; layout, images and animations aren\'t shown';

  @override
  String pptxSlidesTruncated(int count) {
    return 'Only the first $count slides are shown';
  }

  @override
  String get pptxSlideEmpty => '(no text on this slide)';

  @override
  String get play => 'Play';

  @override
  String get pause => 'Pause';

  @override
  String get playbackRate => 'Speed';

  @override
  String get audioFailed => 'Couldn\'t play this file on this system';

  @override
  String get videoFailed => 'Couldn\'t play this video';

  @override
  String get reply => 'Reply';

  @override
  String get forward => 'Forward';

  @override
  String get wrote => 'wrote:';

  @override
  String get composeFrom => 'From';

  @override
  String get composeSenderSearch => 'Search sender';

  @override
  String get composeSenderNoMatch => 'No matching mailbox';

  @override
  String get composeRecipientsHint => 'Type an address, then press Enter';

  @override
  String get composeBodyHint => 'Write your message…';

  @override
  String get composeAttach => 'Attach files';

  @override
  String get composeImageTooLarge => 'Image is too large (5 MB max)';

  @override
  String get composeImageTooMany => 'At most 10 images in the message body';

  @override
  String get composeDropFolderIgnored => 'Folders can\'t be attached';

  @override
  String get composeAiSelectFirst => 'Select the text you want rewritten first';

  @override
  String get composeAiSelectionHasEmbed =>
      'The selection contains an image, so it can\'t be rewritten';

  @override
  String get composeAiSelectionGone =>
      'The original selection is gone — select the text again';

  @override
  String get composeAttachmentTitle => 'Attachments';

  @override
  String composeAttachmentCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count attachments',
      one: '1 attachment',
    );
    return '$_temp0';
  }

  @override
  String composeAttachmentTotal(String size) {
    return 'Total $size';
  }

  @override
  String composeTooManyAttachments(int count) {
    return 'At most $count attachments';
  }

  @override
  String composeTooManyInline(int count) {
    return 'At most $count inline images';
  }

  @override
  String composeTooLarge(String limit) {
    return 'Attachments exceed the limit ($limit)';
  }

  @override
  String get composeNoRecipient => 'Add at least one recipient';

  @override
  String composeBadRecipient(String address) {
    return 'Not a valid address: $address';
  }

  @override
  String get composeEmptyBody => 'The message body can\'t be empty';

  @override
  String get composeSenderUnavailable => 'Sender address unavailable';

  @override
  String get composeNoMailbox => 'No usable sender mailbox';

  @override
  String get composeQuotaUnlimited => 'Sending is unlimited';

  @override
  String composeQuotaUsed(int used) {
    return '$used sent';
  }

  @override
  String composeQuotaRemaining(int remaining) {
    return '$remaining left';
  }

  @override
  String composeQuotaDay(int used, int limit) {
    return 'Today $used/$limit';
  }

  @override
  String composeQuotaTotal(int used, int limit) {
    return 'Quota $used/$limit';
  }

  @override
  String get composeQuotaExhausted => 'Sending quota used up';

  @override
  String get composeQuotaUnknown => 'Quota unknown';

  @override
  String get composeQuotaBanned => 'Your role isn\'t allowed to send';

  @override
  String get composeQuotaInternal => 'Internal mailboxes only';

  @override
  String get composeInternalOnlyHint =>
      'Your quota only allows sending to internal mailboxes; external addresses will be rejected by the server';

  @override
  String get composeRemoveRecipient => 'Remove';

  @override
  String get composeRecentRecipients => 'Recent';

  @override
  String get sending => 'Sending…';

  @override
  String sendingProgress(int percent) {
    return 'Sending $percent%';
  }

  @override
  String get sendSuccess => 'Sent';

  @override
  String get sendQueued => 'Added to Outbox — it will send once you\'re online';

  @override
  String get sendQueuedRetry =>
      'No network — saved to Outbox and will retry automatically';

  @override
  String get sendUnknownResult =>
      'Send result unknown — the server may already have it. Check the Outbox before resending.';

  @override
  String sendAttachmentMissing(String name) {
    return 'Attachment is no longer on this device: $name';
  }

  @override
  String get sendDraftCorrupted => 'Draft is corrupted and can\'t be resent';

  @override
  String get sendNow => 'Send now';

  @override
  String get sendLater => 'Save to Outbox';

  @override
  String get outbox => 'Outbox';

  @override
  String get outboxEmpty => 'Outbox is empty';

  @override
  String get outboxPending => 'Queued';

  @override
  String get outboxSending => 'Sending';

  @override
  String get outboxFailed => 'Failed';

  @override
  String outboxAttempts(int count) {
    return 'Tried $count time(s)';
  }

  @override
  String outboxLastError(String error) {
    return 'Reason: $error';
  }

  @override
  String get outboxUnknownResultHint =>
      'This message may already have been sent. Confirm the recipient didn\'t get it before resending.';

  @override
  String get outboxRetry => 'Retry';

  @override
  String get outboxDiscard => 'Delete';

  @override
  String get outboxDiscardConfirm =>
      'Delete this unsent message? Its contents will be lost.';

  @override
  String get draft => 'Draft';

  @override
  String get draftSaved => 'Draft saved';

  @override
  String draftSavedAt(String when) {
    return 'Saved $when';
  }

  @override
  String get draftDiscard => 'Discard draft';

  @override
  String get draftDiscardConfirm =>
      'Discard this draft? Its contents will be lost.';

  @override
  String get draftEmpty => 'No drafts yet';

  @override
  String get draftsHint =>
      'Drafts live on this device only — they don\'t sync with the web app';

  @override
  String get discardChanges => 'Discard these changes?';

  @override
  String get keepEditing => 'Keep editing';

  @override
  String get discard => 'Discard';

  @override
  String get composeFailedStayHint =>
      'Your message is still in the editor — fix it and try again';

  @override
  String get outboxSent => 'Sent';

  @override
  String get outboxUnknown => 'Result unknown';

  @override
  String get drafts => 'Drafts';

  @override
  String get sendSavedToOutbox =>
      'Saved to Outbox — it will be sent automatically';

  @override
  String get composeLargeAttachmentHint =>
      'Large attachments are uploaded in chunks — keep the app open until it finishes';

  @override
  String get close_ => 'Close';

  @override
  String get composeCloseTooltip => 'Close (Esc)';

  @override
  String get composeQuotedAttached =>
      'The original message will be quoted below your text';

  @override
  String get mailUnavailable => 'Can\'t load the original message';

  @override
  String get outboxFlush => 'Send all now';

  @override
  String get outboxHint =>
      'Messages here are queued on this device and sent one at a time. Retrying sends a real message — the server has no way to tell a duplicate.';

  @override
  String outboxAddressed(String to) {
    return 'Addressed to $to';
  }

  @override
  String get syncStatusTitle => 'Sync status';

  @override
  String get syncStateSyncing => 'Syncing…';

  @override
  String get syncStateWaiting => 'Waiting';

  @override
  String get syncStateStopped => 'Stopped';

  @override
  String syncedCount(int count) {
    return 'Synced $count';
  }

  @override
  String unsyncedCount(int count) {
    return '$count to sync';
  }

  @override
  String get unsyncedUnknown => 'Remaining unknown';

  @override
  String get unsyncedUnknownHint =>
      'The server total is only known after a full page of /email/list, so this is blank on a fresh install.';

  @override
  String syncLastSuccess(String time) {
    return 'Last success: $time';
  }

  @override
  String get syncNeverSucceeded => 'No successful sync yet';

  @override
  String syncFailCount(int count) {
    return 'Failed $count times in a row';
  }

  @override
  String get bodyNotSynced => 'Body not fetched yet';

  @override
  String pendingMore(int count) {
    return '$count messages not synced yet · tap to load more';
  }

  @override
  String pendingMorePassive(int count) {
    return '$count messages not synced yet';
  }

  @override
  String get listLoadingMore => 'Loading…';

  @override
  String get listNoMore => 'No more messages';

  @override
  String get listAggregateFooter =>
      'Aggregate view pulls each instance separately — scrolling to the end syncs again';

  @override
  String get syncNowOne => 'Sync now';

  @override
  String get syncNowFailed =>
      'This instance can\'t sync (not signed in, or the session is gone). Sign in again first.';

  @override
  String get syncStarted => 'Sync started';

  @override
  String get syncButtonHint =>
      'Tap to sync now · long-press or right-click for the sync page';

  @override
  String get syncingThisMail => 'Syncing this message…';

  @override
  String get syncBatchBlocked =>
      'This instance can\'t receive mail right now (not signed in, or the session is gone). Sign in again first.';

  @override
  String get pushAutoProvision => 'One-tap setup (deployer)';

  @override
  String get pushAutoProvisionHint =>
      'Creates a relay slot for this device using the deployer admin token. The token is used for this request only — it is never saved to prefs, the keychain, or any log.';

  @override
  String get pushAdminToken => 'Admin token';

  @override
  String get pushAdminTokenHint =>
      'Shown only on this screen; cleared when you leave';

  @override
  String get pushAutoProvisionDone =>
      'Provisioned — instance id and pairing code filled in';

  @override
  String get sendDelay => 'Send delay';

  @override
  String get sendDelayHint =>
      'After you tap Send the message waits this long before actually going out — long enough to cancel if you change your mind.';

  @override
  String get sendDelayNone => 'Send immediately';

  @override
  String sendDelayMinutes(int minutes) {
    return '$minutes min';
  }

  @override
  String queuedNotice(int minutes) {
    return 'Queued — sending in $minutes min. You can cancel it from the send queue bar.';
  }

  @override
  String get sendQueueTitle => 'Send queue';

  @override
  String sendQueueCount(int count) {
    return '$count queued';
  }

  @override
  String sendQueueIn(int seconds) {
    return 'sending in ${seconds}s';
  }

  @override
  String get sendQueueSendNow => 'Send now';

  @override
  String get sendQueueViewAll => 'View all in Outbox';

  @override
  String get sendQueueCancelConfirm =>
      'Cancel this queued message? It will not be sent.';

  @override
  String sendScheduled(int seconds) {
    return 'Sends in ${seconds}s';
  }

  @override
  String get sendQueuedFailed =>
      'Queued failed — the message is still in the editor';

  @override
  String sendScheduledMinutes(int minutes) {
    return 'Sends in $minutes min';
  }

  @override
  String get pushAdminTokenNeeded => 'Enter the admin token first';

  @override
  String get pushBuiltInApplied =>
      'Pre-filled from this build; the pairing code is stored in the keychain only.';

  @override
  String get aiTitle => 'AI';

  @override
  String get aiSubtitle => 'Bring your own key';

  @override
  String get aiPrivacyNotice =>
      'Text from your message is sent to the provider you configure. The key is stored in this device\'s keychain and never leaves it except in requests to that provider.';

  @override
  String get aiProviderSection => 'Provider';

  @override
  String get aiModelSection => 'Model';

  @override
  String get aiModelLabel => 'Model';

  @override
  String get aiModelHint => 'Model name — type it, or use Fetch to pick one';

  @override
  String get aiBaseUrlLabel => 'Endpoint URL';

  @override
  String get aiBaseUrlHint => 'https://api.openai.com/v1';

  @override
  String get aiApiFormatLabel => 'API format';

  @override
  String get aiApiFormatOpenai => 'OpenAI-compatible';

  @override
  String get aiApiFormatAnthropic => 'Anthropic';

  @override
  String get aiApiFormatNewapi => 'New API';

  @override
  String get aiBaseUrlHintAnthropic => 'https://api.anthropic.com';

  @override
  String get aiBaseUrlHintNewapi =>
      'https://your-gateway-host — with or without /v1';

  @override
  String get aiBaseUrlInvalid => 'The URL must start with http:// or https://';

  @override
  String get aiModelsFetch => 'Fetch';

  @override
  String get aiModelsFetchNeedKey => 'Save a key first';

  @override
  String get aiModelsFetchNeedUrl => 'Fill in the URL first';

  @override
  String get aiModelsEmpty =>
      'This endpoint has no model list — just type the name';

  @override
  String aiModelsFailed(String message) {
    return 'Couldn\'t fetch: $message';
  }

  @override
  String get aiTestConnection => 'Test connection';

  @override
  String get aiTestNeedModel =>
      'A model name is needed to test — fetch one or type it';

  @override
  String aiTestOk(int chars) {
    return 'Connected — the model returned $chars characters';
  }

  @override
  String get aiTestOkNoText =>
      'Connected (only reasoning came back, no visible text — normal for a reasoning model; nothing wrong)';

  @override
  String aiTestFailed(String message) {
    return 'Connection failed: $message';
  }

  @override
  String get aiKeySection => 'API key';

  @override
  String get aiKeyLabel => 'API key';

  @override
  String get aiKeyStored => 'A key is saved';

  @override
  String get aiKeyNotStored => 'No key saved yet';

  @override
  String get aiKeySave => 'Save';

  @override
  String get aiKeyPaste => 'Paste';

  @override
  String get aiKeyPasteEmpty => 'Nothing on the clipboard to paste';

  @override
  String get aiKeyClear => 'Clear';

  @override
  String get aiKeySaved => 'Key saved';

  @override
  String get aiKeyCleared => 'Key cleared';

  @override
  String get aiKeyEmpty => 'Enter a key first';

  @override
  String get aiKeyWhitespace =>
      'The key contains a space or newline — check the paste';

  @override
  String get aiKeyDegraded =>
      'This device\'s keychain is unavailable, so the key can\'t be stored. The entry above will not survive a restart.';

  @override
  String get aiFeaturesSection => 'Features';

  @override
  String get aiInlineContinuation => 'Suggest the next sentence as I pause';

  @override
  String get aiInlineContinuationHint =>
      'Costs one call every time you stop typing';

  @override
  String get aiPreflight => 'Check before sending';

  @override
  String get aiPreflightHint =>
      'Local checks are free; asking the model costs one call';

  @override
  String get aiSubjectSuggest => 'Suggest a subject line';

  @override
  String get aiSubjectSuggestHint =>
      'Tap in the subject row to fill one in; an existing subject is used as reference';

  @override
  String get aiPolish => 'Polish the message';

  @override
  String get aiPolishHint =>
      'Open the sheet from the compose toolbar: pick a tone, add notes, then tap Generate to replace your body (the quote is untouched; undoable)';

  @override
  String get aiPolishTooltip => 'Polish the whole message';

  @override
  String get aiPolishNote =>
      'Only your own text is polished — the quoted message is left exactly as is.';

  @override
  String get aiPolishExtraHint =>
      'Extra requirements (optional), e.g. keep the terminology, don\'t change how I address them';

  @override
  String get aiPolishGenerate => 'Generate';

  @override
  String get aiPolishReplaceAll => 'Replace the body';

  @override
  String get aiPolishIdle => 'Pick a tone, add notes, then tap Generate.';

  @override
  String get aiSubjectEmpty =>
      'Write some body text first — that\'s what the subject is drawn from';

  @override
  String get aiPolishEmpty => 'The body is still empty';

  @override
  String get aiPolishFailed =>
      'Polishing returned nothing — the body is unchanged';

  @override
  String get aiBudgetSection => 'Usage';

  @override
  String get aiDailyLimit => 'Daily call limit';

  @override
  String get aiDailyLimitHint =>
      'A soft limit — it warns, it never blocks. 0 means unlimited.';

  @override
  String aiUsedToday(int used) {
    return 'Used today: $used';
  }

  @override
  String get aiUnavailable => 'Fill in your key to turn these on';

  @override
  String syncNextIn(int seconds) {
    return 'next in ${seconds}s';
  }

  @override
  String get unreadMail => 'Unread';

  @override
  String get filterByMailbox => 'Filter by mailbox';

  @override
  String get toggleMailboxList => 'Show or hide the mailbox list';

  @override
  String get filterByMailboxHint =>
      'Takes effect on tap; at least one stays selected';

  @override
  String get selectAll => 'Select all';

  @override
  String unreadCount(int count) {
    return '$count unread';
  }

  @override
  String get mailboxKeptOne => 'At least one mailbox has to stay selected';

  @override
  String get syncStageSynced => 'Synced';

  @override
  String get syncStageSyncing => 'Syncing';

  @override
  String get syncStagePending => 'Pending';

  @override
  String get syncStagePendingBody => 'No body';

  @override
  String get syncStagePendingAttachment => 'No attachment';

  @override
  String get syncAllNow => 'Sync everything now';

  @override
  String get outboxPendingZero => 'Nothing waiting to be sent';

  @override
  String get syncPanelPendingEmpty => 'Nothing left to sync';

  @override
  String get mailTab => 'Mail';

  @override
  String instanceCount(int count) {
    return '$count instances';
  }

  @override
  String get allInstancesAllMailboxes => 'All instances · all mailboxes';

  @override
  String mailboxCountSelected(int count) {
    return '$count mailboxes selected';
  }

  @override
  String get syncPanelSyncedEmpty => 'Nothing synced yet';

  @override
  String attachmentProgress(int done, int total) {
    return '$done/$total attachments';
  }

  @override
  String syncBatchDone(int bodies, int attachments) {
    return 'Synced $bodies bodies and $attachments attachments';
  }

  @override
  String get syncBatchNothing => 'Nothing left to sync';

  @override
  String syncBatchMore(int mails) {
    return 'Synced $mails; more are waiting (tap again to continue)';
  }

  @override
  String get aiSuggest => 'AI suggestions';

  @override
  String get aiSuggestHint =>
      'Read a message and see what\'s worth doing — tap one to do it (reply / forward / remind / delete…)';

  @override
  String get aiSuggestPanelTitle => 'AI suggestions';

  @override
  String aiSuggestReading(int chars) {
    return 'Read: subject, sender, body ($chars chars)';
  }

  @override
  String aiSuggestAttachments(int count) {
    return '+ $count attachment names';
  }

  @override
  String aiSuggestQuotedDropped(int chars) {
    return 'quoted text trimmed · $chars chars original';
  }

  @override
  String aiSuggestTruncated(int chars) {
    return 'Body too long — using the first $chars chars';
  }

  @override
  String get aiSuggestFetchingBody => 'Fetching the full message…';

  @override
  String get aiSuggestAnalyzing => 'Analyzing…';

  @override
  String get aiSuggestReanalyze => 'Re-analyze';

  @override
  String get aiSuggestRetry => 'Retry';

  @override
  String get aiSuggestParseFailed =>
      'Couldn\'t read a suggestion out of the model\'s reply:';

  @override
  String get aiSuggestTopPick => 'Top pick';

  @override
  String get aiSuggestActionReply => 'Reply';

  @override
  String get aiSuggestActionForward => 'Forward';

  @override
  String get aiSuggestActionDelete => 'Delete';

  @override
  String get aiSuggestActionMarkRead => 'Mark as read';

  @override
  String get aiSuggestActionMarkUnread => 'Mark as unread';

  @override
  String get aiSuggestActionStar => 'Add star';

  @override
  String get aiSuggestActionUnstar => 'Remove star';

  @override
  String get aiSuggestActionRemind => 'Remind me later';

  @override
  String get aiSuggestActionNone => 'Nothing to do';

  @override
  String aiSuggestDeleteConfirm(String subject) {
    return 'Delete \"$subject\"?';
  }

  @override
  String get remindTitle => 'When should we remind you?';

  @override
  String get remindToday => 'Today 6:00 PM';

  @override
  String get remindTomorrow => 'Tomorrow 9:00 AM';

  @override
  String get remindNextMonday => 'Next Monday 9:00 AM';

  @override
  String get remindCustom => 'Custom…';

  @override
  String get remindPast => 'That time has already passed';

  @override
  String remindScheduled(String time) {
    return 'We\'ll remind you at $time';
  }

  @override
  String selectedCount(int count) {
    return '$count selected';
  }

  @override
  String selectionActionWithCount(String action, int count) {
    return '$action ($count selected)';
  }

  @override
  String get selectionClear => 'Clear selection';

  @override
  String selectionDeleteConfirm(int count) {
    return 'Delete the $count selected messages? This cannot be undone.';
  }

  @override
  String selectionUnread(int count) {
    return '$count unread';
  }

  @override
  String selectionWithAttachments(int count) {
    return '$count with attachments';
  }

  @override
  String selectionTimeRange(String from, String to) {
    return '$from – $to';
  }

  @override
  String selectionSelectAll(int count) {
    return 'Select all ($count loaded)';
  }

  @override
  String get selectionStale =>
      'The selected messages are no longer in this list';

  @override
  String get mailboxTitle => 'Mailbox management';

  @override
  String get mailboxAdd => 'Add mailbox';

  @override
  String get mailboxAddTitle => 'Add mailbox';

  @override
  String get mailboxAddFullAddress => 'Full email address';

  @override
  String get mailboxDomainUnavailable =>
      'Domain list unavailable — please type the full address';

  @override
  String get mailboxAddDisabledByServer => 'This instance has adding disabled';

  @override
  String get mailboxAddDenied =>
      'This account may not add mailboxes — ask your administrator';

  @override
  String get mailboxNeedLogin => 'Sign in to this instance first';

  @override
  String get mailboxAddVerifyRequired =>
      'This instance requires a human check — add it on the web';

  @override
  String get mailboxOpenWeb => 'Add on the web';

  @override
  String mailboxRemoveConfirm(String email) {
    return 'Delete “$email”? Its mail will be permanently deleted too — this cannot be undone.';
  }

  @override
  String mailboxRemoved(String email) {
    return 'Deleted $email';
  }

  @override
  String mailboxAdded(String email) {
    return 'Added $email';
  }

  @override
  String get mailboxRename => 'Rename';

  @override
  String get mailboxPin => 'Pin to top';

  @override
  String get mailboxPrimaryBadge => 'Primary';

  @override
  String mailboxPrefixTooShort(int n) {
    return 'Prefix must be at least $n characters';
  }

  @override
  String get mailboxInvalidAddress => 'That is not a valid email address';

  @override
  String get mailboxEmptyName => 'Name cannot be empty';

  @override
  String get mailboxNameTooLong => 'Name must be at most 30 characters';
}
