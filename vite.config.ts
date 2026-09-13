import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import path from 'path';
import tailwindcss from '@tailwindcss/vite';

const host = process.env.TAURI_DEV_HOST;
const isWin7Supermium = process.env.VITE_WIN7_SUPERMIUM === 'true';

function oklchToCss(
  lightness: string,
  lightnessIsPercent: boolean,
  chroma: string,
  hue: string,
  alpha?: string
) {
  const rawLightness = Number(lightness);
  const l = lightnessIsPercent ? rawLightness / 100 : rawLightness;
  const c = Number(chroma);
  const h = (Number(hue) * Math.PI) / 180;
  const a = c * Math.cos(h);
  const b = c * Math.sin(h);
  const l_ = l + 0.3963377774 * a + 0.2158037573 * b;
  const m_ = l - 0.1055613458 * a - 0.0638541728 * b;
  const s_ = l - 0.0894841775 * a - 1.291485548 * b;
  const l3 = l_ * l_ * l_;
  const m3 = m_ * m_ * m_;
  const s3 = s_ * s_ * s_;
  const r = 4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309692326 * s3;
  const g = -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3;
  const bChannel = -0.0041960863 * l3 - 0.7034186147 * m3 + 1.707614701 * s3;
  const gamma = (value: number) =>
    value <= 0.0031308 ? 12.92 * value : 1.055 * Math.pow(value, 1 / 2.4) - 0.055;
  const channel = (value: number) => Math.round(Math.max(0, Math.min(1, gamma(value))) * 255);
  const rgb = [channel(r), channel(g), channel(bChannel)];
  if (alpha === undefined)
    return `#${rgb.map((value) => value.toString(16).padStart(2, '0')).join('')}`;
  const opacity = alpha.endsWith('%') ? Number.parseFloat(alpha) / 100 : Number.parseFloat(alpha);
  return `rgba(${rgb.join(',')},${Math.max(0, Math.min(1, opacity))})`;
}

function replaceLegacyOklch(css: string) {
  return css.replace(
    /oklch\(\s*([+-]?[\d.]+)(%)?\s+([+-]?[\d.]+)\s+([+-]?[\d.]+)(?:deg)?(?:\s*\/\s*([+-]?[\d.]+%?))?\s*\)/g,
    (_match, lightness, percent, chroma, hue, alpha) =>
      oklchToCss(lightness, percent === '%', chroma, hue, alpha)
  );
}

function normalizeHexColor(value: string | undefined) {
  if (!value) return undefined;
  const match = value.trim().match(/^#([0-9a-f]{3}|[0-9a-f]{6}|[0-9a-f]{8})$/i);
  if (!match) return undefined;
  let hex = match[1];
  if (hex.length === 3) hex = hex.split('').map((char) => char + char).join('');
  return `#${hex.slice(0, 6)}`;
}

function hexToRgba(hex: string, alpha: number) {
  const channels = [1, 3, 5].map((index) => Number.parseInt(hex.slice(index, index + 2), 16));
  return `rgba(${channels.join(',')},${Math.max(0, Math.min(1, alpha))})`;
}

function replaceLegacyColorMix(css: string) {
  // Resolve against the first declaration for each variable. In the generated
  // stylesheet :root precedes .dark; letting later .dark declarations overwrite
  // these values would bake dark colors into light-mode legacy fallbacks.
  const variables = new Map<string, string>([
    ['background', '#ffffff'],
    ['foreground', '#333333'],
    ['muted', '#f9fafb'],
    ['muted-foreground', '#6b7280'],
    ['accent', '#e0f2fe'],
    ['accent-foreground', '#1e3a8a'],
    ['border', '#e5e7eb'],
    ['input', '#e5e7eb'],
    ['primary', '#3b82f6'],
    ['primary-foreground', '#ffffff'],
    ['destructive', '#ef4444'],
    ['sidebar', '#f9fafb'],
    ['sidebar-foreground', '#333333'],
    ['sidebar-primary', '#3b82f6'],
    ['sidebar-primary-foreground', '#ffffff'],
    ['sidebar-accent', '#e0f2fe'],
    ['sidebar-border', '#e5e7eb'],
  ]);

  for (const match of css.matchAll(/--([\w-]+)\s*:\s*([^;{}]+);/g)) {
    if (!variables.has(match[1])) variables.set(match[1], match[2].trim());
  }

  const resolveVariableColor = (name: string, seen = new Set<string>()): string | undefined => {
    if (seen.has(name)) return undefined;
    seen.add(name);
    const value = variables.get(name)?.trim();
    const directHex = normalizeHexColor(value);
    if (directHex) return directHex;
    if (!value) return undefined;
    const reference = value.match(/^var\(--([\w-]+)(?:\s*,\s*([^)]+))?\)$/);
    if (!reference) return undefined;
    return (
      resolveVariableColor(reference[1], seen) ||
      (reference[2] ? normalizeHexColor(reference[2]) : undefined)
    );
  };

  // Tailwind minifies `var(--token) 15%` to `var(--token)15%`, so whitespace
  // before the percentage must be optional for WebView2 109 conversion.
  let output = css.replace(
    /color-mix\(in\s+(?:oklab|srgb),\s*var\(--([\w-]+)\)\s*([\d.]+)%\s*,\s*transparent\s*\)/gi,
    (_match, name: string, alpha: string) => {
      const color = resolveVariableColor(name);
      return color ? hexToRgba(color, Number.parseFloat(alpha) / 100) : `var(--${name})`;
    }
  );

  output = output.replace(
    /color-mix\(in\s+(?:oklab|srgb),\s*transparent\s*,\s*var\(--([\w-]+)\)\s*([\d.]+)%\s*\)/gi,
    (_match, name: string, alpha: string) => {
      const color = resolveVariableColor(name);
      return color ? hexToRgba(color, Number.parseFloat(alpha) / 100) : `var(--${name})`;
    }
  );

  output = output.replace(
    /color-mix\(in\s+(?:oklab|srgb),\s*currentColor\s*[\d.]+%\s*,\s*transparent\s*\)/gi,
    'currentColor'
  );

  output = output.replace(
    /color-mix\(in\s+(?:oklab|srgb),\s*(#[0-9a-f]{3,8})\s*([\d.]+)%\s*,\s*transparent\s*\)/gi,
    (match, rawColor: string, alpha: string) => {
      const color = normalizeHexColor(rawColor);
      return color ? hexToRgba(color, Number.parseFloat(alpha) / 100) : match;
    }
  );

  return output;
}

function win7LegacyCssPlugin() {
  return {
    name: 'win7-legacy-css',
    generateBundle(_options: unknown, bundle: Record<string, { type?: string; source?: string }>) {
      for (const [fileName, asset] of Object.entries(bundle)) {
        if (
          asset.type !== 'asset' ||
          !fileName.endsWith('.css') ||
          typeof asset.source !== 'string'
        )
          continue;

        const legacyCss = replaceLegacyOklch(asset.source);
        asset.source = replaceLegacyColorMix(legacyCss)
          .concat(
            '\n/* Win7/Chromium 109 explicit active-tab color fallback */\n' +
              '[data-slot="tabs-trigger"][data-state="active"],[role="tab"][aria-selected="true"]{color:#333!important}\n' +
              '.dark [data-slot="tabs-trigger"][data-state="active"],.dark [role="tab"][aria-selected="true"]{color:#e5e5e5!important}\n' +
              '.text-muted-foreground\\/5{color:rgba(107,114,128,.05)!important}\n' +
              '.dark .text-muted-foreground\\/5{color:rgba(163,163,163,.05)!important}\n' +
              '[data-slot="tabs-trigger"][data-state="active"] svg,[role="tab"][aria-selected="true"] svg{color:inherit;fill:currentColor;stroke:currentColor}\n'
          );
      }
    },
  };
}

// https://vite.dev/config/
export default defineConfig({
  server: {
    fs: {
      // Allow access to plugin directory
      allow: ['..', '../..', '../../..'],
    },
    strictPort: true,
    host: host || false,
    hmr: host
      ? {
          protocol: 'ws',
          host,
          port: 5173,
        }
      : undefined,
    watch: {
      // 3. tell Vite to ignore watching `src-tauri`
      ignored: ['**/src-tauri/**'],
    },
  },
  plugins: [react(), tailwindcss(), ...(isWin7Supermium ? [win7LegacyCssPlugin()] : [])],
  resolve: {
    alias: {
      '@': path.resolve(__dirname, './src'),
      '@/plugins': path.resolve(__dirname, './plugins'),
    },
  },
  build: {
    // Tauri uses Chromium on Windows and WebKit on macOS and Linux
    target: process.env.TAURI_ENV_PLATFORM == 'windows' ? 'chrome105' : 'safari13',
    // don't minify for debug builds
    minify: !process.env.TAURI_ENV_DEBUG ? 'esbuild' : false,
    // produce sourcemaps for debug builds
    sourcemap: !!process.env.TAURI_ENV_DEBUG,
    // 多入口配置：主应用、同步器
    rollupOptions: {
      input: {
        main: path.resolve(__dirname, 'index.html'),
        syncer: path.resolve(__dirname, 'syncer.html'),
      },
    },
  },
});
