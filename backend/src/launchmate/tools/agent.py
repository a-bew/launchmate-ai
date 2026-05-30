import os
import json
import re
import requests
from bs4 import BeautifulSoup
from dotenv import load_dotenv
from langchain_openai import ChatOpenAI
from langchain.tools import tool
from langchain_core.messages import HumanMessage, SystemMessage
from langgraph.prebuilt import create_react_agent
from .bright_tools import serp_search, UNLOCKER_ZONE, BRIGHT_DATA_ENDPOINT

load_dotenv()

OPENROUTER_API_KEY = os.getenv("OPENROUTER_API_KEY")
BRIGHTDATA_API_KEY = os.getenv("BRIGHTDATA_API_KEY")
LLM_MODEL = os.getenv("LLM_MODEL", "step-3.5-flash")

llm = ChatOpenAI(
    model=LLM_MODEL,
    openai_api_key=OPENROUTER_API_KEY,
    openai_api_base="https://openrouter.ai/api/v1",
    temperature=0.1,
    max_tokens=2048,
)

@tool
def search_web(query: str) -> str:
    """Search the live web with Bright Data SERP API."""
    try:
        results = serp_search(query, country="us", num=5)
        if not results:
            return "No results found."
        formatted = []
        for i, r in enumerate(results, 1):
            formatted.append(f"{i}. {r['title']}\n   Link: {r['link']}\n   Snippet: {r['snippet']}")
        return "\n\n".join(formatted)
    except Exception as e:
        return f"Search error: {str(e)}"

@tool
def scrape_url(url: str) -> str:
    """Scrape a webpage using Bright Data Web Unlocker."""
    try:
        payload = {"zone": UNLOCKER_ZONE, "url": url, "format": "raw"}
        headers = {"Authorization": f"Bearer {BRIGHTDATA_API_KEY}", "Content-Type": "application/json"}
        r = requests.post(BRIGHT_DATA_ENDPOINT, headers=headers, json=payload, timeout=30)
        r.raise_for_status()
        soup = BeautifulSoup(r.text, "html.parser")
        for tag in soup(["script", "style", "nav", "footer", "header"]):
            tag.decompose()
        text = soup.get_text(separator=" ", strip=True)
        return text[:3000]
    except Exception as e:
        return f"Scrape error: {str(e)}"

tools = [search_web, scrape_url]

SYSTEM_PROMPT = (
    "You are SignalSight, an enterprise strategy intelligence agent.\n"
    "You MUST follow this process for every task:\n"
    "1. Use `search_web` to find relevant, recent articles.\n"
    "2. Choose the 2 most promising results and use `scrape_url` to extract content.\n"
    "3. AFTER scraping EXACTLY 2 URLs, produce a FINAL answer. Do NOT call more tools after that.\n"
    "4. Always include source URLs in your final report.\n"
    "Do NOT skip scraping. A report without scraped content is incomplete."
)

agent = create_react_agent(llm, tools, state_modifier=SYSTEM_PROMPT, recursion_limit=50)

def generate_strategy_brief(research: str, query: str) -> dict:
    prompt = f"""Based on this research about "{query}":

{research[:4000]}

Produce ONLY valid JSON:
{{
  "brief_title": "...",
  "date": "YYYY-MM-DD",
  "key_signals": [
    {{
      "signal_type": "product_launch|regulatory|competitive|market",
      "entity": "...",
      "description": "...",
      "source_url": "...",
      "recommended_action": "..."
    }}
  ],
  "executive_summary": "...",
  "overall_threat_level": "high|medium|low",
  "next_steps": ["...", "..."]
}}"""
    messages = [
        SystemMessage(content="Respond with ONLY raw JSON. No markdown."),
        HumanMessage(content=prompt)
    ]
    response = llm.invoke(messages)
    raw = response.content.strip()
    raw = re.sub(r"^```(?:json)?\s*", "", raw)
    raw = re.sub(r"\s*```$", "", raw)
    try:
        return json.loads(raw)
    except json.JSONDecodeError as e:
        return {"error": str(e), "raw_output": raw}

def run_signal_sight(query: str, log_callback=None) -> dict:
    result = agent.invoke({"messages": [HumanMessage(content=query)]})
    final_report = result["messages"][-1].content
    brief = generate_strategy_brief(final_report, query)
    return {"research": final_report, "brief": brief}