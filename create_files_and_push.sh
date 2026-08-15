#!/usr/bin/env bash
set -euo pipefail

REPO="jhearv/mi-bloqueador-pro"
DIR="$(pwd)/${REPO##*/}"

# Comprobaciones básicas
if ! command -v gh >/dev/null 2>&1; then
  echo "gh (GitHub CLI) no encontrado. Instálalo o usa la UI de GitHub."
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "gh no está autenticado. Ejecuta: gh auth login"
  exit 1
fi

# Crear directorio del proyecto (si no existe)
mkdir -p "$DIR"
cd "$DIR"

# Evitar sobrescribir si ya existe un repo git local
if [ -d .git ]; then
  echo "Ya existe un repositorio Git local en $DIR. Para evitar sobrescribir, abortando."
  echo "Si quieres sobrescribir, elimina .git y vuelve a ejecutar este script."
  exit 1
fi

mkdir -p .github/workflows
mkdir -p scripts

# .github/workflows/convert.yml
cat > .github/workflows/convert.yml <<'YML'
name: Auto Convert Rules

on:
  schedule:
    - cron: '0 0 * * *'
  workflow_dispatch:

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: write

    steps:
      - name: Checkout repo
        uses: actions/checkout@v3

      - name: Setup Node
        uses: actions/setup-node@v3
        with:
          node-version: '18'

      - name: Run script
        run: node scripts/convert.js

      - name: Commit changes
        run: |
          git config --local user.email "github-actions[bot]@users.noreply.github.com"
          git config --local user.name "github-actions[bot]"
          git add rules.json
          git commit -m "Auto-update rules.json" || exit 0
          git push
YML

# scripts/convert.js
cat > scripts/convert.js <<'JS'
'use strict';

const fs = require('fs');
const http = require('http');
const https = require('https');
const { URL } = require('url');

function fetchWithRedirects(rawUrl, maxRedirects = 5) {
  return new Promise((resolve, reject) => {
    let redirects = 0;

    function _fetch(urlToGet) {
      let urlObj;
      try {
        urlObj = new URL(urlToGet);
      } catch (err) {
        return reject(new Error(`URL inválida: ${urlToGet}`));
      }

      const getter = urlObj.protocol === 'http:' ? http.get : https.get;
      const req = getter(urlObj, (res) => {
        const { statusCode, headers } = res;

        if (statusCode >= 300 && statusCode < 400 && headers.location) {
          if (redirects >= maxRedirects) {
            return reject(new Error('Demasiadas redirecciones'));
          }
          redirects++;
          const next = new URL(headers.location, urlObj).toString();
          return _fetch(next);
        }

        if (statusCode && statusCode >= 400) {
          return reject(new Error(`Error HTTP ${statusCode} fetching ${urlToGet}`));
        }

        let data = '';
        res.setEncoding('utf8');
        res.on('data', chunk => data += chunk);
        res.on('end', () => resolve(data));
      });

      req.on('error', reject);
      req.setTimeout(30_000, () => {
        req.abort();
        reject(new Error('Timeout al descargar'));
      });
    }

    _fetch(rawUrl);
  });
}

function isLikelyDomain(s) {
  return /^[\w.-]+$/.test(s) && s.indexOf('.') > 0 && !s.includes('..') && !s.includes('*');
}

function extractDomainFromAdblockRule(line) {
  try {
    if (line.startsWith('||')) {
      const after = line.slice(2);
      const idx = after.search(/[\^\/$]/);
      const domain = idx === -1 ? after : after.slice(0, idx);
      return domain.trim();
    }

    if (line.startsWith('|http') || line.startsWith('|https') || line.startsWith('|')) {
      const maybe = line.replace(/^\|/, '').split('$')[0].trim();
      try {
        const u = new URL(maybe);
        return u.hostname;
      } catch (e) {
        const m = maybe.match(/\/\/([^\/]+)/);
        if (m) return m[1];
      }
    }

    return null;
  } catch (e) {
    return null;
  }
}

function extractDomainFromHostsLine(line) {
  const parts = line.split(/\s+/).filter(Boolean);
  if (parts.length >= 2) {
    const d = parts[1].trim();
    if (isLikelyDomain(d)) return d;
  }
  return null;
}

function sanitizeDomain(d) {
  if (!d) return null;
  d = d.trim().replace(/^(\*+\.)+/, '');
  d = d.replace(/[^\w.-]/g, '');
  if (d.startsWith('www.')) d = d.slice(4);
  d = d.toLowerCase();
  if (!isLikelyDomain(d)) return null;
  if (/^\d+\.\d+\.\d+\.\d+$/.test(d)) return null;
  return d;
}

async function processLists() {
  let sourcesRaw;
  try {
    sourcesRaw = fs.readFileSync('sources.txt', 'utf8');
  } catch (err) {
    console.error('No se pudo leer sources.txt:', err.message);
    process.exit(1);
  }

  const sources = sourcesRaw
    .split(/\r?\n/)
    .map(s => s.trim())
    .filter(Boolean)
    .filter(s => !s.startsWith('#'));

  if (sources.length === 0) {
    console.log('No hay fuentes en sources.txt. Escribiendo rules.json vacío.');
    fs.writeFileSync('rules.json', JSON.stringify([], null, 2), 'utf8');
    process.exit(0);
  }

  const domainSet = new Set();
  const rules = [];
  let nextId = 1;

  for (const src of sources) {
    try {
      console.log(`Descargando ${src} ...`);
      const content = await fetchWithRedirects(src);
      const lines = content.split(/\r?\n/);

      for (let raw of lines) {
        if (!raw) continue;
        let line = raw.trim();

        if (
          line.startsWith('!') ||
          line.startsWith('#') ||
          line.startsWith('[') ||
          line.toLowerCase().startsWith('rem')
        ) {
          continue;
        }

        if (line.startsWith('@@')) continue;

        const hashIndex = line.indexOf(' #');
        if (hashIndex !== -1) line = line.slice(0, hashIndex).trim();

        let domain = extractDomainFromAdblockRule(line);

        if (!domain) {
          domain = extractDomainFromHostsLine(line);
        }

        if (!domain) {
          const token = line.split(/\s+/)[0];
          if (token && token.indexOf('.') > 0 && !token.includes('/')) {
            domain = token;
          }
        }

        domain = sanitizeDomain(domain);

        if (!domain) continue;
        if (domain.includes('*')) continue;
        if (domainSet.has(domain)) continue;

        domainSet.add(domain);

        rules.push({
          id: nextId++,
          priority: 1,
          action: { type: 'block' },
          condition: {
            urlFilter: `||${domain}^`,
            resourceTypes: ['script', 'image', 'xmlhttprequest', 'sub_frame']
          }
        });

        if (rules.length >= 5000) break;
      }

      console.log(`Procesada fuente: ${src}. Reglas totales hasta ahora: ${rules.length}`);
    } catch (err) {
      console.error(`Error procesando ${src}: ${err.message}`);
    }

    if (rules.length >= 5000) {
      console.log('Se alcanzó el límite de 5000 reglas; ignorando entradas adicionales.');
      break;
    }
  }

  const finalRules = rules.slice(0, 5000);

  try {
    const json = JSON.stringify(finalRules, null, 2);
    fs.writeFileSync('rules.json', json, 'utf8');

    const check = JSON.parse(fs.readFileSync('rules.json', 'utf8'));
    if (!Array.isArray(check)) {
      throw new Error('El JSON generado no es un array');
    }

    const ids = new Set();
    for (const r of check) {
      if (ids.has(r.id)) {
        throw new Error('IDs duplicados detectados después de la escritura');
      }
      ids.add(r.id);
    }

    console.log(`Generadas ${check.length} reglas con éxito.`);
  } catch (err) {
    console.error('Error al escribir o validar rules.json:', err.message);
    try {
      fs.writeFileSync('rules.json', '[]', 'utf8');
      console.log('Se escribió fallback rules.json vacío.');
    } catch (e2) {
      console.error('No se pudo escribir el fallback rules.json:', e2.message);
      process.exit(1);
    }
  }
}

if (require.main === module) {
  processLists().catch(err => {
    console.error('Error inesperado en el proceso:', err && err.message ? err.message : err);
    try {
      if (!fs.existsSync('rules.json')) {
        fs.writeFileSync('rules.json', '[]', 'utf8');
      }
    } catch (e) {
      // ignore
    }
    process.exit(0);
  });
}
JS

# sources.txt
cat > sources.txt <<'TXT'
https://raw.githubusercontent.com/AdguardTeam/AdguardFilters/master/BaseFilter/sections/adservers.txt
TXT

# initial rules.json
cat > rules.json <<'TXT'
[]
TXT

# Initialize git and push
git init -b main
git add .
git commit -m "Add workflow, script, sources.txt and initial rules.json"

# get SSH url from gh and add remote
SSHURL="$(gh repo view "$REPO" --json sshUrl --jq .sshUrl 2>/dev/null || true)"
if [ -z "$SSHURL" ]; then
  SSHURL="git@github.com:$REPO.git"
fi
git remote add origin "$SSHURL"

# push
git push -u origin main

echo "Archivos creados y subidos a: https://github.com/$REPO"
