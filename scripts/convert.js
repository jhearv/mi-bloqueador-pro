const fs = require('fs');
const https = require('https');

function fetchList(url) {
  return new Promise((resolve, reject) => {
    https.get(url, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => resolve(data));
    }).on('error', reject);
  });
}

async function processLists() {
  const sources = fs.readFileSync('sources.txt', 'utf-8').split('\n').filter(Boolean);
  let id = 1;
  const rules = [];
  const domainSet = new Set();

  for (const url of sources) {
    try {
      const content = await fetchList(url.trim());
      const lines = content.split('\n');

      for (let line of lines) {
        line = line.trim();
        if (line.startsWith('||') && line.endsWith('^')) {
          const domain = line.slice(2, -1);
          
          if (domain && !domainSet.has(domain) && !domain.includes('*')) {
            domainSet.add(domain);
            rules.push({
              id: id++,
              priority: 1,
              action: { type: 'block' },
              condition: {
                urlFilter: `||${domain}^`,
                resourceTypes: ['script', 'image', 'xmlhttprequest', 'sub_frame']
              }
            });
          }
        }
      }
    } catch (e) {
      console.error(`Error procesando: ${url}`);
    }
  }

  const finalRules = rules.slice(0, 5000);
  fs.writeFileSync('rules.json', JSON.stringify(finalRules, null, 2));
  console.log(`Generadas ${finalRules.length} reglas con éxito.`);
}

processLists();
