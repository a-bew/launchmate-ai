import pytest
from unittest.mock import patch, MagicMock
from launchmate.tools.agent import run_signal_sight, generate_strategy_brief

@pytest.fixture
def mock_agent_invoke():
    with patch('launchmate.tools.agent.agent.invoke') as mock:
        mock.return_value = {"messages": [MagicMock(content="Mock research report.")]}
        yield mock

@pytest.fixture
def mock_llm_brief():
    with patch('launchmate.tools.agent.llm.invoke') as mock:
        mock_response = MagicMock()
        mock_response.content = '{"brief_title":"Test","date":"2026-01-01","key_signals":[],"executive_summary":"Test summary","overall_threat_level":"low","next_steps":["Step 1"]}'
        mock.return_value = mock_response
        yield mock

def test_agent_returns_research_and_brief(mock_agent_invoke, mock_llm_brief):
    result = run_signal_sight("What is the latest trend in AI?")
    assert "research" in result
    assert "brief" in result
    assert "executive_summary" in result["brief"]

def test_generate_strategy_brief_valid_json():
    research = "Some research text."
    query = "test query"
    with patch('launchmate.tools.agent.llm.invoke') as mock_llm:
        mock_response = MagicMock()
        mock_response.content = '{"brief_title":"X","date":"2026-01-01","key_signals":[],"executive_summary":"Y","overall_threat_level":"medium","next_steps":["Z"]}'
        mock_llm.return_value = mock_response
        brief = generate_strategy_brief(research, query)
        assert "error" not in brief
        assert brief["executive_summary"] == "Y"