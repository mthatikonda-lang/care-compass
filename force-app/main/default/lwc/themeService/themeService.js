// Light / dark theme for every Care Compass page.
// Components use CSS variables such as var(--cc-surface, #FFFFFF). Light mode leaves the
// variables unset, so the white fallback shows. Dark mode sets them on the page root.
const KEY = 'cc-theme';

const DARK = {
    // Backgrounds: deep navy page, slightly lifted cards
    '--cc-page': '#090E17',
    '--cc-page-overlay': `url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 1600 900' fill='none' stroke-linecap='round' stroke-linejoin='round'%3E%3Cpath d='M-40 640 H330 L390 520 L470 760 L550 590 L600 640 H1000 L1060 560 L1130 700 L1190 640 H1660' stroke='%23E8A33D' stroke-opacity='.30' stroke-width='2.5'/%3E%3Cpath d='M1130 120 L1410 210 V430 C1410 590 1290 700 1130 760 C970 700 850 590 850 430 V210 Z' stroke='%23FFFFFF' stroke-opacity='.11' stroke-width='3'/%3E%3Ccircle cx='1130' cy='420' r='150' stroke='%23FFFFFF' stroke-opacity='.09' stroke-width='2'/%3E%3Ccircle cx='1130' cy='420' r='230' stroke='%23FFFFFF' stroke-opacity='.06' stroke-width='2'/%3E%3Cg stroke='%23E8A33D' stroke-opacity='.55' stroke-width='5'%3E%3Cpath d='M170 170v36M152 188h36'/%3E%3Cpath d='M1350 700v36M1332 718h36'/%3E%3Cpath d='M640 120v28M626 134h28'/%3E%3Cpath d='M420 420v24M408 432h24'/%3E%3Cpath d='M1480 520v28M1466 534h28'/%3E%3C/g%3E%3Cg fill='%23FFFFFF' fill-opacity='.16'%3E%3Ccircle cx='260' cy='330' r='6'/%3E%3Ccircle cx='980' cy='200' r='5'/%3E%3Ccircle cx='1240' cy='560' r='7'/%3E%3Ccircle cx='560' cy='780' r='5'/%3E%3Ccircle cx='90' cy='520' r='4'/%3E%3C/g%3E%3C/svg%3E") center / cover no-repeat fixed, radial-gradient(640px 420px at 0% 100%, rgba(232, 163, 61, 0.20), transparent 70%), radial-gradient(760px 520px at 100% 0%, rgba(91, 141, 214, 0.22), transparent 70%), linear-gradient(180deg, #0A1224, #080D1A)`,
    '--cc-surface': '#101A2E',
    '--cc-surface-2': '#15203A',
    '--cc-track': '#27324F',
    // Text hierarchy: white headings, soft slate body copy
    '--cc-ink': '#FFFFFF',
    '--cc-text': '#CBD5E1',
    '--cc-muted': '#94A3B8',
    // Glass edges, tinted shadows, gold hover glow
    '--cc-border': 'rgba(255, 255, 255, 0.08)',
    '--cc-border-2': 'rgba(255, 255, 255, 0.16)',
    '--cc-border-hover': 'rgba(229, 169, 60, 0.4)',
    '--cc-edge-top': 'rgba(255, 255, 255, 0.14)',
    '--cc-edge-left': 'rgba(255, 255, 255, 0.06)',
    '--cc-card-shadow': '0 20px 40px -15px rgba(5, 10, 20, 0.6)',
    '--cc-card-shadow-hover': '0 18px 40px -12px rgba(5, 10, 20, 0.7), 0 10px 30px rgba(229, 169, 60, 0.10)',
    // Banner gradient and glowing active pill
    '--cc-hero-1': '#0B1320',
    '--cc-hero-2': '#111D33',
    '--cc-hero-3': '#1A2942',
    '--cc-pill-shadow': '0 0 20px rgba(232, 163, 61, 0.5), 0 6px 16px -4px rgba(232, 163, 61, 0.65), inset 0 1px 0 rgba(255, 255, 255, 0.35)',
    '--cc-glass-bg': 'rgba(15, 25, 42, 0.78)',
    '--cc-glass-blur': 'blur(24px)',
    '--cc-navy': '#2F4378',
    '--cc-navy-2': '#3C5390',
    '--cc-disabled': '#3A4560',
    '--cc-gold-text': '#F3C77A',
    '--cc-green-text': '#7FD1A5',
    '--cc-red-text': '#FF9C86',
    '--cc-purple-text': '#CDBBF5',
    '--cc-gold-tint': 'rgba(232, 163, 61, 0.15)',
    '--cc-green-tint': 'rgba(46, 160, 110, 0.20)',
    '--cc-red-tint': 'rgba(220, 100, 80, 0.20)',
    '--cc-purple-tint': 'rgba(150, 120, 220, 0.22)',
    '--cc-gold-border': 'rgba(232, 163, 61, 0.38)',
    // Salesforce base components (lightning-input and friends)
    '--slds-c-input-text-color': '#F2EFE8',
    '--slds-c-input-label-color': '#CBD5E1',
    '--slds-c-textarea-text-color': '#F2EFE8',
    '--slds-c-combobox-text-color': '#F2EFE8',
    '--sds-c-input-text-color': '#F2EFE8',
    '--sds-c-input-label-color': '#CBD5E1',
    // Field labels, help text and placeholders inside Salesforce base components
    '--lwc-colorTextLabel': '#CBD5E1',
    '--lwc-colorTextDefault': '#E2E8F0',
    '--lwc-colorTextWeak': '#94A3B8',
    '--lwc-colorTextPlaceholder': '#7C8CA6',
    '--slds-g-color-on-surface-1': '#E2E8F0',
    '--slds-g-color-on-surface-2': '#CBD5E1',
    '--slds-g-color-on-surface-3': '#94A3B8'
};

// Salesforce draws form labels with its own global stylesheet, which ignores our variables.
// This sheet only matches while the page is dark, so light mode is untouched.
const LABEL_CSS = `
html[data-cc-theme="dark"] .slds-form-element__label,
html[data-cc-theme="dark"] .slds-form-element__legend,
html[data-cc-theme="dark"] .slds-form-element__label .slds-form-element__label,
html[data-cc-theme="dark"] .slds-radio__label,
html[data-cc-theme="dark"] .slds-checkbox__label .slds-form-element__label { color: #CBD5E1 !important; }
html[data-cc-theme="dark"] .slds-form-element__help { color: #94A3B8 !important; }
html[data-cc-theme="dark"] .slds-required { color: #F87171 !important; }
html[data-cc-theme="dark"] .slds-input::placeholder,
html[data-cc-theme="dark"] .slds-textarea::placeholder { color: #7C8CA6 !important; }
html[data-cc-theme="dark"] .slds-datepicker .slds-form-element__label { color: #444444 !important; }
`;

function ensureLabelStyle() {
    try {
        if (document.getElementById('cc-theme-labels')) return;
        const st = document.createElement('style');
        st.id = 'cc-theme-labels';
        st.textContent = LABEL_CSS;
        document.head.appendChild(st);
    } catch (e) {
        // no document: nothing to style
    }
}

function root() {
    return document.documentElement;
}

export function getTheme() {
    try {
        const saved = window.localStorage.getItem(KEY);
        if (saved === 'dark' || saved === 'light') {
            return saved;
        }
    } catch (e) {
        // storage blocked: fall through to the device setting
    }
    try {
        return window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
    } catch (e) {
        return 'light';
    }
}

export function applyTheme(theme) {
    const el = root();
    if (!el) return;
    Object.keys(DARK).forEach((name) => {
        if (theme === 'dark') {
            el.style.setProperty(name, DARK[name]);
        } else {
            el.style.removeProperty(name);
        }
    });
    ensureLabelStyle();
    el.style.colorScheme = theme === 'dark' ? 'dark' : 'light';
    el.setAttribute('data-cc-theme', theme);
}

export function initTheme() {
    const theme = getTheme();
    applyTheme(theme);
    return theme;
}

export function setTheme(theme) {
    try {
        window.localStorage.setItem(KEY, theme);
    } catch (e) {
        // storage blocked: the choice lasts until the page is reloaded
    }
    applyTheme(theme);
    return theme;
}