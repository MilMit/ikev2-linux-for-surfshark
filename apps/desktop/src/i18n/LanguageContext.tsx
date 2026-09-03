import React, { createContext, useContext, useEffect, useState } from 'react';
import { Language, Translations, translations } from './translations';

interface LanguageContextType {
  language: Language;
  setLanguage: (lang: Language) => void;
  toggleLanguage: () => void;
  t: (key: keyof Translations) => string;
  dir: 'rtl' | 'ltr';
  isRtl: boolean;
}

const STORAGE_KEY = 'milmit_language_preference';

const LanguageContext = createContext<LanguageContextType | undefined>(undefined);

export const LanguageProvider: React.FC<{ children: React.ReactNode }> = ({ children }) => {
  const [language, setLanguageState] = useState<Language>(() => {
    try {
      const stored = localStorage.getItem(STORAGE_KEY);
      if (stored === 'en' || stored === 'fa') return stored;
    } catch {
      // ignore
    }
    // Default to Persian since user requested Persian UI or system default
    return 'fa';
  });

  const dir: 'rtl' | 'ltr' = language === 'fa' ? 'rtl' : 'ltr';
  const isRtl = dir === 'rtl';

  useEffect(() => {
    try {
      localStorage.setItem(STORAGE_KEY, language);
    } catch {
      // ignore
    }
    document.documentElement.lang = language;
    document.documentElement.dir = dir;
    if (isRtl) {
      document.body.classList.add('rtl-layout');
    } else {
      document.body.classList.remove('rtl-layout');
    }
  }, [language, dir, isRtl]);

  const setLanguage = (lang: Language) => {
    setLanguageState(lang);
  };

  const toggleLanguage = () => {
    setLanguageState(prev => (prev === 'fa' ? 'en' : 'fa'));
  };

  const t = (key: keyof Translations): string => {
    const dict = translations[language] || translations.fa;
    return dict[key] || translations.en[key] || String(key);
  };

  return (
    <LanguageContext.Provider
      value={{
        language,
        setLanguage,
        toggleLanguage,
        t,
        dir,
        isRtl,
      }}
    >
      {children}
    </LanguageContext.Provider>
  );
};

export const useI18n = (): LanguageContextType => {
  const context = useContext(LanguageContext);
  if (!context) {
    throw new Error('useI18n must be used within a LanguageProvider');
  }
  return context;
};
