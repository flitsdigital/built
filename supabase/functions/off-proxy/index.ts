// OpenFoodFacts met een gedeelde cache ertussen.
//
// De app praatte rechtstreeks met OFF: drie gelijktijdige requests per zoekopdracht, en een
// cache per toestel. Dat schaalt niet — niet voor ons, en al helemaal niet voor een
// non-profit die op donaties draait.
//
// Deze function kijkt eerst in `public.off_products`. Alleen bij een misser (of een
// verlopen entry) gaat er een request naar OFF, en het resultaat gaat de cache in. Bij
// >99% cache hit betekent dat één request naar OFF per uniek product in plaats van per
// gebruiker — en voor de gebruiker één snelle round-trip in plaats van een race tussen drie
// externe servers.
//
// Aanroep:
//   POST /functions/v1/off-proxy  { "search": "volle melk" }
//   POST /functions/v1/off-proxy  { "barcode": "8712800147008" }
//
// Antwoord: { "products": [...], "cached": true|false, "stale": true|false }
// `products` is de ruwe OFF-vorm; de app parseert 'm zelf, net als voorheen.

import { createClient } from "jsr:@supabase/supabase-js@2";

const FIELDS = [
  "code",
  "product_name",
  "brands",
  "nutriments",
  "image_front_small_url",
  "serving_quantity",
  "product_quantity",
  "categories_tags",
].join(",");

// Producten wijzigen zelden. Binnen deze termijn serveren we uit de cache zonder OFF aan te
// raken; daarbuiten proberen we te verversen maar geven we de oude waarde terug als OFF
// onbereikbaar is. Zoeken blijft dus werken als OFF plat ligt.
const TTL_MS = 30 * 24 * 60 * 60 * 1000;

// Zelfde User-Agent als de app had: OFF throttelt zonder.
const HEADERS = { "User-Agent": "Built/1.0 (edge-proxy)" };

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  // Service role: RLS staat schrijven aan niemand toe, zodat een client de cache niet kan
  // vergiftigen. Alleen deze function komt erlangs.
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

async function fromOFF(key: string): Promise<unknown[] | null> {
  const [kind, ...rest] = key.split(":");
  const value = rest.join(":");

  if (kind === "barcode") {
    const url =
      `https://world.openfoodfacts.org/api/v2/product/${encodeURIComponent(value)}.json?fields=${FIELDS}`;
    const res = await fetch(url, { headers: HEADERS });
    if (res.status === 404) return []; // bestaat niet — dat is een geldig antwoord
    if (!res.ok) return null;
    const body = await res.json();
    return body.product ? [body.product] : [];
  }

  // Zoeken: search-a-licious is in de praktijk de snelste en stabielste, met de cgi-servers
  // als terugval. Geen sort_by — op popularity sorteren overstemt de tekstmatch volledig.
  const endpoints = [
    `https://search.openfoodfacts.org/search?q=${encodeURIComponent(value)}&langs=nl,en&page_size=20&fields=${FIELDS}`,
    `https://nl.openfoodfacts.org/cgi/search.pl?search_terms=${encodeURIComponent(value)}&search_simple=1&action=process&json=1&page_size=20&fields=${FIELDS}`,
    `https://world.openfoodfacts.org/cgi/search.pl?search_terms=${encodeURIComponent(value)}&search_simple=1&action=process&json=1&page_size=20&fields=${FIELDS}`,
  ];

  let reachable = false;
  for (const url of endpoints) {
    try {
      const res = await fetch(url, { headers: HEADERS });
      if (!res.ok) continue;
      const body = await res.json();
      const items = body.hits ?? body.products ?? [];
      reachable = true;
      if (Array.isArray(items) && items.length > 0) return items;
    } catch {
      // volgende endpoint
    }
  }
  // Bereikbaar maar leeg is iets anders dan onbereikbaar: het eerste cachen we, het tweede
  // niet — anders staat een storing dertig dagen in de cache.
  return reachable ? [] : null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "POST verwacht" }, 405);

  let body: { search?: string; barcode?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "ongeldige body" }, 400);
  }

  const search = body.search?.trim().toLowerCase();
  const barcode = body.barcode?.trim();
  if (!search && !barcode) return json({ error: "search of barcode verplicht" }, 400);
  if (search && search.length < 2) return json({ products: [], cached: false });

  const key = barcode ? `barcode:${barcode}` : `search:${search}`;

  const { data: hit } = await admin
    .from("off_products")
    .select("payload, fetched_at")
    .eq("cache_key", key)
    .maybeSingle();

  const age = hit ? Date.now() - new Date(hit.fetched_at).getTime() : Infinity;
  if (hit && age < TTL_MS) {
    return json({ products: hit.payload, cached: true, stale: false });
  }

  const fresh = await fromOFF(key);
  if (fresh === null) {
    // OFF onbereikbaar. Een verlopen entry is beter dan niets — dit is precies waarom de
    // cache ook bij een storing waarde heeft.
    if (hit) return json({ products: hit.payload, cached: true, stale: true });
    return json({ error: "OpenFoodFacts niet bereikbaar" }, 503);
  }

  // Lege zoekresultaten niet cachen: dan blijft een tikfout dertig dagen leeg staan, en
  // een product dat later aan OFF toegevoegd wordt blijft onvindbaar.
  if (fresh.length > 0 || barcode) {
    await admin
      .from("off_products")
      .upsert({ cache_key: key, payload: fresh, fetched_at: new Date().toISOString() });
  }

  return json({ products: fresh, cached: false, stale: false });
});
