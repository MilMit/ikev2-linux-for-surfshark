export type Language = 'en' | 'fa';

export interface Translations {
  // Topbar
  appTitle: string;
  terminal: string;
  credentials: string;
  settings: string;
  language: string;
  langNameEn: string;
  langNameFa: string;

  // Connection & Status
  connected: string;
  disconnected: string;
  connecting: string;
  cancelling: string;
  verifying: string;
  protectedVia: string;
  tunnelActive: string;
  establishingTunnel: string;
  revertingRoutes: string;
  selectServerToSecure: string;
  clickToDisconnect: string;
  clickToCancel: string;
  clickToConnect: string;

  // Main Action Buttons
  secureMyConnection: string;
  disconnectBtn: string;
  cancelBtn: string;

  // Fastest Server & Smart Connect
  fastestServerBtn: string;
  testingFastestNodes: string;
  smartConnect: string;
  pingServers: string;
  probing: string;
  splitApps: string;

  // Route Beam
  yourIp: string;
  directTraffic: string;
  encryptedTunnel: string;
  destination: string;

  // Network HUD
  international: string;
  iranBypass: string;
  killSwitch: string;
  bypassedOn: string;
  fullTunnel: string;
  armedOn: string;
  disabled: string;
  directStandby: string;
  killSwitchToggleHint: string;

  // Metrics Grid
  latency: string;
  publicIp: string;
  exitNode: string;

  // Traffic & Usage
  trafficChartTitle: string;
  download: string;
  upload: string;
  speed: string;
  totalTransferred: string;

  // Locations Page
  selectLocation: string;
  searchLocations: string;
  tabAll: string;
  tabFavorites: string;
  tabFast: string;
  tabRecent: string;
  serversCount: string;
  noServersFound: string;
  connectToServer: string;
  ms: string;
  offline: string;

  // Settings Grid
  settingsTitle: string;
  credentialsTitle: string;
  credentialsDesc: string;
  vpnProtectionTitle: string;
  vpnProtectionDesc: string;
  splitTunnelingTitle: string;
  splitTunnelingDesc: string;
  devicesTitle: string;
  devicesDesc: string;
  diagnosticsTitle: string;
  diagnosticsDesc: string;
  usageTitle: string;
  usageDesc: string;
  advancedTitle: string;
  advancedDesc: string;
  languageTitle: string;
  languageDesc: string;
  directAppLauncher: string;
  domainIpPolicies: string;
  connectedDevices: string;
  guestHotspot: string;
  customLocationLists: string;
  diagnosticsAndHealth: string;

  // Feature Options
  autoConnect: string;
  autoConnectDesc: string;
  killSwitchIranPassthrough: string;
  killSwitchIranPassthroughDesc: string;
  dnsGuard: string;
  dnsGuardDesc: string;
  ipv6Guard: string;
  ipv6GuardDesc: string;
  iranRoutingMode: string;
  iranRoutingModeDesc: string;
  customBypassRules: string;
  customBypassRulesDesc: string;
  addRule: string;
  deleteRule: string;
  rulePlaceholder: string;

  // Diagnostics
  runDiagnostics: string;
  runningDiagnostics: string;
  diagMtu: string;
  diagDns: string;
  diagLatency: string;
  diagRoute: string;

  // Modals
  credentialsModalTitle: string;
  credentialsModalDesc: string;
  username: string;
  password: string;
  saveCredentials: string;
  cancel: string;
  credentialsSaved: string;
  terminalModalTitle: string;
  clearLogs: string;
  copyLogs: string;
  logsCopied: string;

  // General / Navigation
  back: string;
  on: string;
  off: string;
  close: string;
  enabled: string;
}

export const translations: Record<Language, Translations> = {
  en: {
    appTitle: 'MilMit Secure',
    terminal: 'Live Connection Terminal',
    credentials: 'Surfshark Credentials',
    settings: 'Settings & Protection',
    language: 'Language',
    langNameEn: 'English',
    langNameFa: 'فارسی (Persian)',

    connected: 'Protected',
    disconnected: 'Not Connected',
    connecting: 'Connecting…',
    cancelling: 'Cancelling…',
    verifying: 'Verifying Security…',
    protectedVia: 'Protected via',
    tunnelActive: 'Tunnel active',
    establishingTunnel: 'Establishing secure IKEv2 tunnel and verifying data path…',
    revertingRoutes: 'Reverting routing tables to direct…',
    selectServerToSecure: 'Select a server and secure your connection',
    clickToDisconnect: 'Click to Disconnect',
    clickToCancel: 'Click to Cancel',
    clickToConnect: 'Click to Connect',

    secureMyConnection: 'Secure My Connection',
    disconnectBtn: 'Disconnect',
    cancelBtn: 'Cancel Connection',

    fastestServerBtn: '⚡ Quick Connect to Fastest Server',
    testingFastestNodes: 'Testing Low-Latency Nodes…',
    smartConnect: 'Smart Connect',
    pingServers: 'Ping Servers',
    probing: 'Probing…',
    splitApps: 'Split Apps',

    yourIp: 'Your IP',
    directTraffic: 'Direct Traffic',
    encryptedTunnel: 'Encrypted Tunnel',
    destination: 'Destination',

    international: 'International',
    iranBypass: 'Iran Bypass',
    killSwitch: 'Kill Switch',
    bypassedOn: 'Bypassed (ON)',
    fullTunnel: 'Full Tunnel',
    armedOn: 'Armed (ON)',
    disabled: 'Disabled',
    directStandby: 'Direct / Standby',
    killSwitchToggleHint: 'Click to toggle Kill Switch protection',

    latency: 'Latency',
    publicIp: 'Public IP',
    exitNode: 'Exit Node',

    trafficChartTitle: 'Live Network Traffic',
    download: 'Download',
    upload: 'Upload',
    speed: 'Speed',
    totalTransferred: 'Total Transferred',

    selectLocation: 'Select Server Location',
    searchLocations: 'Search city, country or host…',
    tabAll: 'All',
    tabFavorites: 'Favorites',
    tabFast: 'Fastest (<100ms)',
    tabRecent: 'Recent',
    serversCount: 'servers available',
    noServersFound: 'No servers matched your filter',
    connectToServer: 'Connect',
    ms: 'ms',
    offline: 'Timeout',

    settingsTitle: 'Settings & Protection',
    credentialsTitle: 'Surfshark Credentials',
    credentialsDesc: 'Configure root-protected service username & password',
    vpnProtectionTitle: 'VPN Protection',
    vpnProtectionDesc: 'Auto-connect, lockdown mode, startup & recovery',
    splitTunnelingTitle: 'Split Tunneling',
    splitTunnelingDesc: 'Isolated namespace apps, domains and IP bypass',
    devicesTitle: 'Hotspot & Devices',
    devicesDesc: 'Protected hotspot, client routing, quotas & isolation',
    diagnosticsTitle: 'Network Diagnostics',
    diagnosticsDesc: 'Ping tests, DNS leaks, MTU/MSS & live path verify',
    usageTitle: 'Data Usage & Speed',
    usageDesc: 'Real-time traffic waveform and historic statistics',
    advancedTitle: 'Advanced Tools',
    advancedDesc: 'Custom server lists, candidate routes & support bundle',
    languageTitle: 'Language & Appearance',
    languageDesc: 'Choose interface language and layout direction (English / فارسی)',
    directAppLauncher: 'Direct App Launcher',
    domainIpPolicies: 'Domain / IP Policies',
    connectedDevices: 'Connected Devices',
    guestHotspot: 'Guest Hotspot',
    customLocationLists: 'Custom Location Lists',
    diagnosticsAndHealth: 'Diagnostics & Health',

    autoConnect: 'Auto-Connect on Startup',
    autoConnectDesc: 'Automatically connect to optimal server when system starts',
    killSwitchIranPassthrough: 'Kill Switch Iran Passthrough',
    killSwitchIranPassthroughDesc: 'Allow domestic Iranian banking and local services during VPN drops',
    dnsGuard: 'DNS Leak Protection',
    dnsGuardDesc: 'Enforce private encrypted DNS resolution',
    ipv6Guard: 'IPv6 Leak Block',
    ipv6GuardDesc: 'Disable IPv6 leaks when tunnel is established',
    iranRoutingMode: 'Domestic Routing Bypass',
    iranRoutingModeDesc: 'Route Iranian IP ranges directly outside the tunnel',
    customBypassRules: 'Custom Direct Bypass Rules',
    customBypassRulesDesc: 'Enter domains or IP subnets to route directly outside VPN',
    addRule: 'Add Rule',
    deleteRule: 'Remove',
    rulePlaceholder: 'example.com or 192.168.1.0/24',

    runDiagnostics: 'Run Network Diagnostics',
    runningDiagnostics: 'Analyzing Network Stack…',
    diagMtu: 'MTU / MSS Optimization',
    diagDns: 'DNS Leak Test',
    diagLatency: 'Gateway Latency',
    diagRoute: 'Tunnel Path Verification',

    credentialsModalTitle: 'Surfshark Service Credentials',
    credentialsModalDesc: 'Enter manual connection credentials from Surfshark Dashboard (Account > Manual setup > Credentials).',
    username: 'Service Username',
    password: 'Service Password',
    saveCredentials: 'Save Credentials',
    cancel: 'Cancel',
    credentialsSaved: 'Credentials securely stored.',
    terminalModalTitle: 'Live Connection Terminal',
    clearLogs: 'Clear Logs',
    copyLogs: 'Copy Output',
    logsCopied: 'Terminal output copied to clipboard.',

    back: 'Back',
    on: 'ON',
    off: 'OFF',
    close: 'Close',
    enabled: 'Enabled',
  },
  fa: {
    appTitle: 'میلمیت سکیور',
    terminal: 'ترمینال زنده لاگ و اتصال',
    credentials: 'اطلاعات کاربری سرف‌شارک',
    settings: 'تنظیمات و امنیت',
    language: 'زبان برنامه',
    langNameEn: 'English (انگلیسی)',
    langNameFa: 'فارسی (Persian)',

    connected: 'متصل و امن',
    disconnected: 'غیرمتصل',
    connecting: 'در حال برقراری اتصال…',
    cancelling: 'در حال لغو اتصال…',
    verifying: 'بررسی امنیت مسیر…',
    protectedVia: 'محافظت شده از طریق',
    tunnelActive: 'تونل فعال است',
    establishingTunnel: 'در حال راه‌اندازی تونل امن IKEv2 و اعتبارسنجی مسیر داده…',
    revertingRoutes: 'در حال بازگردانی جدول مسیریابی به حالت مستقیم…',
    selectServerToSecure: 'یک سرور انتخاب کنید و اتصال خود را ایمن سازید',
    clickToDisconnect: 'کلیک جهت قطع اتصال',
    clickToCancel: 'کلیک جهت لغو اتصال',
    clickToConnect: 'کلیک جهت اتصال امن',

    secureMyConnection: 'اتصال امن به سرور',
    disconnectBtn: 'قطع اتصال',
    cancelBtn: 'لغو اتصال',

    fastestServerBtn: '⚡ اتصال سریع به پرسرعت‌ترین سرور',
    testingFastestNodes: 'در حال بررسی کمترین پینگ…',
    smartConnect: 'اتصال هوشمند',
    pingServers: 'پینگ سرورها',
    probing: 'در حال سنجش…',
    splitApps: 'تفکیک ترافیک برنامه‌ها',

    yourIp: 'آی‌پی شما',
    directTraffic: 'ترافیک مستقیم',
    encryptedTunnel: 'تونل رمزگذاری شده',
    destination: 'مقصد',

    international: 'ترافیک بین‌الملل',
    iranBypass: 'بای‌پس سایت‌های ایرانی',
    killSwitch: 'کیل سوییچ (Kill Switch)',
    bypassedOn: 'بای‌پاس فعال (مستقیم)',
    fullTunnel: 'تونل کامل',
    armedOn: 'فعال و مسلح',
    disabled: 'غیرفعال',
    directStandby: 'مستقیم / آماده‌باش',
    killSwitchToggleHint: 'کلیک برای فعال/غیرفعال‌سازی کیل سوییچ',

    latency: 'تاخیر (پینگ)',
    publicIp: 'آی‌پی عمومی',
    exitNode: 'سرور خروجی',

    trafficChartTitle: 'نمودار مصرف زنده ترافیک',
    download: 'دریافت',
    upload: 'ارسال',
    speed: 'سرعت',
    totalTransferred: 'مجموع مصرف',

    selectLocation: 'انتخاب موقعیت سرور',
    searchLocations: 'جستجوی شهر، کشور یا آدرس سرور…',
    tabAll: 'همه سرورها',
    tabFavorites: 'علاقه‌مندی‌ها',
    tabFast: 'پرسرعت (<۱۰۰ms)',
    tabRecent: 'اخیر',
    serversCount: 'سرور در دسترس',
    noServersFound: 'سروری مطابق فیلتر یافت نشد',
    connectToServer: 'اتصال',
    ms: 'میلی‌ثانیه',
    offline: 'قطع / تایم‌اوت',

    settingsTitle: 'تنظیمات و امنیت',
    credentialsTitle: 'اطلاعات کاربری سرف‌شارک',
    credentialsDesc: 'تنظیم نام کاربری و رمز دستی سرویس با امنیت سطح روت',
    vpnProtectionTitle: 'محافظت و امنیت VPN',
    vpnProtectionDesc: 'اتصال خودکار، کیل سوییچ، بازیابی خودکار و استارتاپ',
    splitTunnelingTitle: 'اسپلیت تونلینگ (Split Tunneling)',
    splitTunnelingDesc: 'جداسازی برنامه‌ها، لیست سایت‌های مستقیم و بای‌پس اختصاصی',
    devicesTitle: 'هات‌اسپات و اشتراک اینترنت',
    devicesDesc: 'اشتراک امن اینترنت، سهمیه‌بندی و ایزوله‌سازی کلاینت‌ها',
    diagnosticsTitle: 'عیب‌یابی پیشرفته شبکه',
    diagnosticsDesc: 'تست پینگ، نشت دی‌ان‌اس (DNS Leak)، پکت لاس و بهینه‌سازی MTU',
    usageTitle: 'گزارش ترافیک و سرعت',
    usageDesc: 'نمودار نرخ مصرف لحظه‌ای و سابقه آماری داده‌ها',
    advancedTitle: 'ابزارهای پیشرفته',
    advancedDesc: 'مدیریت سرورهای سفارشی، مسیرهای جایگزین و بسته پشتیبانی',
    languageTitle: 'زبان و ظاهر برنامه',
    languageDesc: 'تغییر زبان رابط کاربری و چیدمان صفحه (فارسی / English)',
    directAppLauncher: 'اجرای مستقیم برنامه‌ها (Direct Launcher)',
    domainIpPolicies: 'سیاست‌های دامنه و آی‌پی',
    connectedDevices: 'دستگاه‌های متصل به هات‌اسپات',
    guestHotspot: 'هات‌اسپات مهمان',
    customLocationLists: 'لیست سرورهای سفارشی',
    diagnosticsAndHealth: 'عیب‌یابی و سلامت شبکه',

    autoConnect: 'اتصال خودکار هنگام روشن شدن سیستم',
    autoConnectDesc: 'بلافاصله پس از ورود به سیستم، اتصال به بهترین سرور فعال شود',
    killSwitchIranPassthrough: 'عبور سایت‌های ایرانی از کیل‌سوییچ',
    killSwitchIranPassthroughDesc: 'در صورت قطعی VPN، دسترسی به بانک‌ها و سایت‌های داخلی قطع نشود',
    dnsGuard: 'جلوگیری از نشت DNS',
    dnsGuardDesc: 'هدایت کلیه درخواست‌های نام به دی‌ان‌اس اختصاصی و امن',
    ipv6Guard: 'مسدودسازی نشت IPv6',
    ipv6GuardDesc: 'غیرفعال‌سازی پروتکل IPv6 در زمان اتصال تونل جهت حفظ حریم خصوصی',
    iranRoutingMode: 'مسیریابی مستقیم آی‌پی‌های ایران',
    iranRoutingModeDesc: 'هدایت مستقیم رنج آی‌پی‌های داخلی از خارج تونل VPN',
    customBypassRules: 'قوانین بای‌پس مستقیم سفارشی',
    customBypassRulesDesc: 'دامنه‌ها یا آی‌پی‌های دلخواه جهت عبور از خارج وی‌پی‌ان',
    addRule: 'افزودن قانون',
    deleteRule: 'حذف',
    rulePlaceholder: 'مثال: example.com یا 192.168.1.0/24',

    runDiagnostics: 'اجرای عیب‌یابی شبکه',
    runningDiagnostics: 'در حال بررسی استک شبکه…',
    diagMtu: 'بهینه‌سازی MTU / MSS',
    diagDns: 'تست نشت DNS',
    diagLatency: 'تاخیر گیت‌وی',
    diagRoute: 'تایید مسیر تونل',

    credentialsModalTitle: 'اطلاعات اتصال دستی سرف‌شارک',
    credentialsModalDesc: 'نام کاربری و رمز عبور بخش Manual setup پنل کاربری سرف‌شارک را در کادرهای زیر وارد کنید.',
    username: 'نام کاربری سرویس (Username)',
    password: 'رمز عبور سرویس (Password)',
    saveCredentials: 'ذخیره مشخصات',
    cancel: 'انصراف',
    credentialsSaved: 'اطلاعات با موفقیت ذخیره شد.',
    terminalModalTitle: 'ترمینال و لاگ زنده اتصال',
    clearLogs: 'پاکسازی لاگ‌ها',
    copyLogs: 'کپی خروجی',
    logsCopied: 'متن ترمینال در کلیپ‌بورد کپی شد.',

    back: 'بازگشت',
    on: 'روشن',
    off: 'خاموش',
    close: 'بستن',
    enabled: 'فعال',
  },
};
