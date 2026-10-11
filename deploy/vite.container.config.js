// Local Vite config for the container runtime only — NOT part of the app.
//
// The app's own config sets `server.allowedHosts` from GEV_ALLOWED_HOSTS, but
// its host-check middleware reads `preview.allowedHosts` when serving under
// `vite preview` (build/allowedHosts.js), and the app never sets that. The
// result: in preview mode the Host-header gate silently ignores
// GEV_ALLOWED_HOSTS and only loopback/IP hosts pass, so any reverse-proxy
// hostname is 403'd before reaching the app.
//
// This wrapper loads the app's config, then sets `preview.allowedHosts` to the
// same resolved value. It touches nothing else; the app source is unmodified.
// GEV_ALLOWED_HOSTS must name the exact public hostname(s) the proxy serves.

import baseConfig from '../server/standalone/vite.config.js';
import {
  resolveAllowedHosts,
  DEFAULT_ALLOWED_HOSTS,
} from '../build/allowedHosts.js';

export default async function containerConfig(env) {
  const resolved =
    typeof baseConfig === 'function' ? await baseConfig(env) : baseConfig;
  const allowed = resolveAllowedHosts(process.env.GEV_ALLOWED_HOSTS);
  return {
    ...resolved,
    preview: {
      ...resolved.preview,
      allowedHosts:
        allowed.length > DEFAULT_ALLOWED_HOSTS.length
          ? allowed
          : DEFAULT_ALLOWED_HOSTS,
      host: process.env.HOST || '0.0.0.0',
      port: parseInt(process.env.PORT || '4173', 10),
    },
  };
}
