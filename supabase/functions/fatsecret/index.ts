// FatSecret-proxy. Houdt de client-secret server-side, doet OAuth2 (client_credentials)
// en normaliseert alles naar de Product-vorm die de app verwacht (per 100 g/ml).
//
// Env-vars (Supabase → Edge Functions → fatsecret → Secrets):
//   FATSECRET_CLIENT_ID, FATSECRET_CLIENT_SECRET
//
// Request-body: { "action": "search", "query": "kipfilet" }
//            of { "action": "barcode", "barcode": "8710400012345" }

const FS_ID = Deno.env.get("FATSECRET_CLIENT_ID") ?? "";
const FS_SECRET = Deno.env.get("FATSECRET_CLIENT_SECRET") ?? "";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

// Token cachen binnen een warme instance.
let cachedToken: { token: string; exp: number } | null = null;

async function getToken(): Promise<string> {
  if (cachedToken && cachedToken.exp > Date.now() + 30_000) return cachedToken.token;
  const basic = btoa(`${FS_ID}:${FS_SECRET}`);
  const res = await fetch("https://oauth.fatsecret.com/connect/token", {
    method: "POST",
    headers: {
      Authorization: `Basic ${basic}`,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: "grant_type=client_credentials&scope=basic",
  });
  const json = await res.json();
  if (!json.access_token) throw new Error("FatSecret token faalde: " + JSON.stringify(json));
  cachedToken = { token: json.access_token, exp: Date.now() + (json.expires_in ?? 86400) * 1000 };
  return cachedToken.token;
}

async function fs(params: Record<string, string>): Promise<any> {
  const token = await getToken();
  const url = new URL("https://platform.fatsecret.com/rest/server.api");
  url.searchParams.set("format", "json");
  for (const [k, v] of Object.entries(params)) url.searchParams.set(k, v);
  const res = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
  return await res.json();
}

const num = (v: unknown): number => {
  const n = parseFloat(String(v));
  return isNaN(n) ? 0 : n;
};

// "Per 100g - Calories: 52kcal | Fat: 0.17g | Carbs: 13.81g | Protein: 0.26g"
function fromDescription(desc: string) {
  const grab = (re: RegExp): number => {
    const m = desc.match(re);
    return m ? parseFloat(m[1]) : 0;
  };
  const kcal = grab(/Calories:\s*([\d.]+)\s*kcal/i);
  const fat = grab(/Fat:\s*([\d.]+)\s*g/i);
  const carbs = grab(/Carbs:\s*([\d.]+)\s*g/i);
  const protein = grab(/Protein:\s*([\d.]+)\s*g/i);

  let ref = 100;
  let servingGrams = 0;
  if (/Per\s+100\s*(?:g|ml)/i.test(desc)) {
    ref = 100;
  } else {
    const paren = desc.match(/\(([\d.]+)\s*(?:g|ml)\)/i);
    const perAmt = desc.match(/Per\s+([\d.]+)\s*(?:g|ml)\b/i);
    if (paren) { ref = parseFloat(paren[1]); servingGrams = ref; }
    else if (perAmt) { ref = parseFloat(perAmt[1]); servingGrams = ref; }
  }
  const f = ref > 0 ? 100 / ref : 1;
  return {
    protein100: +(protein * f).toFixed(1),
    kcal100: Math.round(kcal * f),
    carbs100: +(carbs * f).toFixed(1),
    fat100: +(fat * f).toFixed(1),
    servingGrams,
  };
}

function searchProduct(food: any) {
  const p = fromDescription(food.food_description ?? "");
  return {
    name: food.food_name ?? "",
    brand: food.brand_name ?? "",
    barcode: "",
    protein100: p.protein100,
    kcal100: p.kcal100,
    carbs100: p.carbs100,
    fat100: p.fat100,
    imageURL: "",
    servingGrams: p.servingGrams,
    packageGrams: 0,
  };
}

// food.get.v2: nauwkeurige per-100 uit de metrische portie.
function detailProduct(food: any, barcode: string) {
  if (!food) return null;
  let servings = food?.servings?.serving ?? [];
  if (!Array.isArray(servings)) servings = servings ? [servings] : [];
  const metric = servings.find((s: any) =>
    s.metric_serving_amount && (s.metric_serving_unit === "g" || s.metric_serving_unit === "ml")
  ) ?? servings[0];

  let protein100 = 0, kcal100 = 0, carbs100 = 0, fat100 = 0, servingGrams = 0;
  if (metric) {
    const amt = num(metric.metric_serving_amount) || 100;
    const f = amt > 0 ? 100 / amt : 1;
    protein100 = +(num(metric.protein) * f).toFixed(1);
    kcal100 = Math.round(num(metric.calories) * f);
    carbs100 = +(num(metric.carbohydrate) * f).toFixed(1);
    fat100 = +(num(metric.fat) * f).toFixed(1);
    if (metric.metric_serving_unit === "g") servingGrams = num(metric.metric_serving_amount);
  }
  return {
    name: food.food_name ?? "",
    brand: food.brand_name ?? "",
    barcode,
    protein100, kcal100, carbs100, fat100,
    imageURL: "",
    servingGrams,
    packageGrams: 0,
  };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

  try {
    const { action, query, barcode } = await req.json();

    if (action === "search") {
      const data = await fs({ method: "foods.search", search_expression: query ?? "", max_results: "20" });
      let foods = data?.foods?.food ?? [];
      if (!Array.isArray(foods)) foods = foods ? [foods] : [];
      const products = foods
        .map(searchProduct)
        .filter((p: any) => p.name && (p.protein100 || p.kcal100));
      return json({ products });
    }

    if (action === "barcode") {
      const idData = await fs({ method: "food.find_id_for_barcode", barcode: barcode ?? "" });
      const foodId = idData?.food_id?.value;
      if (!foodId || foodId === "0") return json({ product: null });
      const detail = await fs({ method: "food.get.v2", food_id: String(foodId) });
      return json({ product: detailProduct(detail?.food, barcode ?? "") });
    }

    return json({ error: "unknown action" }, 400);
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
