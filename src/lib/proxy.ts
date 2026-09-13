export type ProxyProtocol = 'http' | 'https' | 'socks5';

export interface ParsedProxyInput {
  type?: ProxyProtocol;
  host?: string;
  port?: string;
  username?: string;
  password?: string;
}

/** Keep IPv6 hosts unbracketed in storage, and bracket them only in endpoints. */
export function formatProxyHost(host: string): string {
  const value = host.trim();
  if (value.startsWith('[') && value.endsWith(']')) return value;
  return value.includes(':') ? `[${value}]` : value;
}

export function formatProxyHostPort(host: string, port: string | number): string {
  return `${formatProxyHost(host)}:${port}`;
}

/** Parse URL, userinfo, bracketed IPv6, plain IPv6, and the legacy 4-field format. */
export function parseProxyInput(input: string): ParsedProxyInput | null {
  let remaining = input.trim();
  if (!remaining) return null;

  const result: ParsedProxyInput = {};
  const protocol = remaining.match(/^(http|https|socks5):\/\//i);
  if (protocol) {
    result.type = protocol[1].toLowerCase() as ProxyProtocol;
    remaining = remaining.slice(protocol[0].length);
  }

  const at = remaining.lastIndexOf('@');
  if (at >= 0) {
    const credentials = remaining.slice(0, at);
    const separator = credentials.indexOf(':');
    if (separator < 1) return null;
    result.username = credentials.slice(0, separator);
    result.password = credentials.slice(separator + 1);
    remaining = remaining.slice(at + 1);
  }

  let host = '';
  let port = '';
  let legacyCredentials: string[] = [];
  if (remaining.startsWith('[')) {
    const closing = remaining.indexOf(']');
    if (closing < 2 || remaining[closing + 1] !== ':') return null;
    host = remaining.slice(1, closing);
    legacyCredentials = remaining.slice(closing + 2).split(':');
    port = legacyCredentials.shift() || '';
  } else {
    const parts = remaining.split(':');
    if (parts.length === 2) {
      [host, port] = parts;
    } else if (parts.length === 4 && !result.username && /^\d+$/.test(parts[1])) {
      [host, port, result.username, result.password] = parts;
    } else {
      const separator = remaining.lastIndexOf(':');
      if (separator < 1) return null;
      host = remaining.slice(0, separator);
      port = remaining.slice(separator + 1);
    }
  }

  if (!result.username && legacyCredentials.length >= 2) {
    result.username = legacyCredentials[0];
    result.password = legacyCredentials[1];
  }
  if (!host.trim() || !/^\d+$/.test(port)) return null;
  result.host = host.trim();
  result.port = port;
  return result;
}
