import requests
import json
import os
from dotenv import load_dotenv

load_dotenv()

BRIGHT_DATA_ENDPOINT = "https://api.brightdata.com/request"
BRIGHTDATA_API_KEY = os.getenv("BRIGHTDATA_API_KEY")
SERP_ZONE = os.getenv("SERP_ZONE", "serp_api2")
UNLOCKER_ZONE = os.getenv("UNLOCKER_ZONE", "web_unlocker1")

def serp_search(query: str, country: str = "us", num: int = 5) -> list[dict]:
    """Search Google via Bright Data SERP API and return organic results."""
    headers = {
        "Authorization": f"Bearer {BRIGHTDATA_API_KEY}",
        "Content-Type": "application/json"
    }
    search_url = (
        f"https://www.google.com/search"
        f"?q={requests.utils.quote(query)}&hl=en&gl={country}&num={num}"
    )
    payload = {
        "zone": SERP_ZONE,
        "url": search_url,
        "format": "json"
    }
    r = requests.post(BRIGHT_DATA_ENDPOINT, headers=headers, json=payload, timeout=30)
    r.raise_for_status()
    data = r.json()

    body = data.get("body", data)
    if isinstance(body, str):
        body = json.loads(body)

    results = (
        body.get("organic")
        or body.get("organic_results")
        or body.get("results")
        or body.get("search_results")
        or body.get("items")
        or []
    )

    return [
        {
            "title": item.get("title", ""),
            "link": item.get("link") or item.get("url", ""),
            "snippet": item.get("snippet") or item.get("description", ""),
        }
        for item in results[:num]
    ]
