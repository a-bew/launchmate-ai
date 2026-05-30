#!/bin/bash
set -e

echo "🤖 Phase 3: SignalSight Agent + Bright Data Integration"

cd backend

# -------------------------------
# tools/bright_tools.py
# -------------------------------
mkdir -p src/launchmate/tools
cat > src/launchmate/tools/bright_tools.py << 'EOF'
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
EOF

# -------------------------------
# tools/agent.py
# -------------------------------
cat > src/launchmate/tools/agent.py << 'EOF'
import os
import json
import re
import requests
from bs4 import BeautifulSoup
from dotenv import load_dotenv
from langchain_openai import ChatOpenAI
from langchain.agents import create_agent
from langchain.tools import tool
from langchain_core.messages import HumanMessage, SystemMessage
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
    """Scrape a webpage using Bright Data Web Unlocker. Returns cleaned text."""
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
    "You are SignalSight, an enterprise strategy intelligence agent. "
    "You MUST follow this process for every task:\n"
    "1. Use `search_web` to find relevant, recent articles about the topic.\n"
    "2. Choose the 2 most promising results from the search and use `scrape_url` to extract their full content.\n"
    "3. Synthesize the scraped content into a detailed, factual report that answers the user's question.\n"
    "4. Always include source URLs in your final report.\n"
    "Do NOT skip scraping. A report without scraped content is incomplete."
)

agent = create_agent(
    llm,
    tools,
    system_prompt=SYSTEM_PROMPT
)

def generate_strategy_brief(research: str, query: str) -> dict:
    """Convert raw research into structured JSON brief."""
    prompt = f"""You are a strategy analyst. Based on this research about "{query}":

{research[:4000]}

Produce ONLY a valid JSON object with this exact structure — no markdown, no explanation, no backticks:
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
        SystemMessage(content=(
            "You are a strategic intelligence analyst. "
            "You must respond with ONLY a raw JSON object. "
            "Do not include ```json fences, markdown, or any text before or after the JSON."
        )),
        HumanMessage(content=prompt)
    ]

    response = llm.invoke(messages)
    raw = response.content.strip()
    raw = re.sub(r"^```(?:json)?\s*", "", raw)
    raw = re.sub(r"\s*```$", "", raw)
    raw = raw.strip()

    try:
        return json.loads(raw)
    except json.JSONDecodeError as e:
        return {"error": str(e), "raw_output": raw}

def run_signal_sight(query: str, log_callback=None) -> dict:
    """Orchestrate agent research and synthesis."""
    messages = [HumanMessage(content=query)]

    for event in agent.stream({"messages": messages}, stream_mode="values"):
        if "messages" in event:
            last = event["messages"][-1]
            if hasattr(last, "tool_calls") and last.tool_calls:
                for tc in last.tool_calls:
                    if log_callback:
                        if tc["name"] == "scrape_url":
                            log_callback(f"🌐 Scraping: `{tc['args'].get('url','')}`")
                        elif tc["name"] == "search_web":
                            log_callback(f"🔍 Searching: `{tc['args'].get('query','')}`")
            if hasattr(last, "content") and last.content and log_callback:
                log_callback(f"💬 Agent: {str(last.content)[:150]}...")

    result = agent.invoke({"messages": messages})
    final_report = result["messages"][-1].content
    brief = generate_strategy_brief(final_report, query)
    return {"research": final_report, "brief": brief}
EOF

# -------------------------------
# tests/test_agent.py
# -------------------------------
mkdir -p tests
cat > tests/test_agent.py << 'EOF'
import pytest
from unittest.mock import patch, MagicMock
from src.launchmate.tools.agent import run_signal_sight, generate_strategy_brief

@pytest.fixture
def mock_serp_search():
    with patch('src.launchmate.tools.bright_tools.serp_search') as mock:
        mock.return_value = [
            {"title": "Test Result", "link": "https://example.com", "snippet": "This is a test snippet."}
        ]
        yield mock

@pytest.fixture
def mock_scrape():
    with patch('src.launchmate.tools.agent.scrape_url') as mock:
        mock.return_value = "Scraped content with important facts."
        yield mock

@pytest.fixture
def mock_llm():
    with patch('src.launchmate.tools.agent.llm') as mock:
        mock_response = MagicMock()
        mock_response.content = '{"brief_title":"Test","date":"2026-01-01","key_signals":[],"executive_summary":"Test summary","overall_threat_level":"low","next_steps":["Step 1"]}'
        mock.invoke.return_value = mock_response
        yield mock

def test_agent_returns_research_and_brief(mock_serp_search, mock_scrape, mock_llm):
    result = run_signal_sight("What is the latest trend in AI?")
    assert "research" in result
    assert "brief" in result
    assert "executive_summary" in result["brief"]

def test_generate_strategy_brief_valid_json():
    research = "Some research text."
    query = "test query"
    with patch('src.launchmate.tools.agent.llm') as mock_llm:
        mock_response = MagicMock()
        mock_response.content = '{"brief_title":"X","date":"2026-01-01","key_signals":[],"executive_summary":"Y","overall_threat_level":"medium","next_steps":["Z"]}'
        mock_llm.invoke.return_value = mock_response
        brief = generate_strategy_brief(research, query)
        assert "error" not in brief
        assert brief["executive_summary"] == "Y"
EOF

# Ensure __init__.py in tools
touch src/launchmate/tools/__init__.py

echo "✅ Phase 3 complete. Now run:"
echo "   cd backend"
echo "   export PYTHONPATH=src   # if not already set"
echo "   poetry run pytest tests/test_agent.py -v"
echo ""
echo "If you have BRIGHTDATA_API_KEY and OPENROUTER_API_KEY in .env, the test will run live (or mocked)."
EOF