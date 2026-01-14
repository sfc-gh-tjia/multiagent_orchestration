-- ============================================================================
-- CORTEX MULTI-AGENT SETUP
-- ============================================================================
-- Replace placeholders: <YOUR_ACCOUNT>, <YOUR_DATABASE>, <YOUR_SCHEMA>,
--                       <YOUR_AGENT_NAME>, <YOUR_ROLE>, <YOUR_PAT_TOKEN>
-- ============================================================================

USE ROLE ACCOUNTADMIN;

-- Step 1: Network Rule (egress to Snowflake API)
CREATE OR REPLACE NETWORK RULE cortex_agent_egress_rule
  MODE = EGRESS
  TYPE = HOST_PORT
  VALUE_LIST = ('<YOUR_ACCOUNT>.snowflakecomputing.com');

-- Step 2: Store PAT Token
CREATE OR REPLACE SECRET cortex_agent_token_secret
  TYPE = GENERIC_STRING
  SECRET_STRING = '<YOUR_PAT_TOKEN>';

-- Step 3: External Access Integration
CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION cortex_agent_external_access
  ALLOWED_NETWORK_RULES = (cortex_agent_egress_rule)
  ALLOWED_AUTHENTICATION_SECRETS = ALL
  ENABLED = TRUE;

-- Step 4: Grant Permissions
GRANT READ ON SECRET cortex_agent_token_secret TO ROLE <YOUR_ROLE>;
GRANT USAGE ON INTEGRATION cortex_agent_external_access TO ROLE <YOUR_ROLE>;

-- Step 5: Agent Caller UDF (duplicate for each sub-agent, change name + URL)
CREATE OR REPLACE FUNCTION call_cortex_agent(user_query STRING)
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.12'
PACKAGES = ('requests', 'snowflake-snowpark-python')
EXTERNAL_ACCESS_INTEGRATIONS = (cortex_agent_external_access)
SECRETS = ('agent_token' = cortex_agent_token_secret)
HANDLER = 'run_agent'
AS
$$
import _snowflake
import requests
import json

def run_agent(user_query):
    try:
        token = _snowflake.get_generic_secret_string('agent_token')
    except Exception as e:
        return f"Error: Could not read secret. {str(e)}"

    url = "https://<YOUR_ACCOUNT>.snowflakecomputing.com/api/v2/databases/<YOUR_DATABASE>/schemas/<YOUR_SCHEMA>/agents/<YOUR_AGENT_NAME>:run"
    
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
        "Accept": "text/event-stream"
    }
    
    payload = {
        "messages": [{"role": "user", "content": [{"type": "text", "text": user_query}]}]
    }
    
    try:
        response = requests.post(url, headers=headers, json=payload, stream=True)
        
        if response.status_code != 200:
            return f"API Error {response.status_code}: {response.text}"
        
        final_answer = []
        current_event = None
        
        for line in response.iter_lines():
            if not line:
                continue
            decoded_line = line.decode('utf-8')
            
            if decoded_line.startswith('event: '):
                current_event = decoded_line[7:].strip()
            
            if decoded_line.startswith('data: '):
                data_str = decoded_line[6:]
                if data_str == '[DONE]':
                    break
                try:
                    data = json.loads(data_str)
                    if current_event == 'response.text.delta' and 'text' in data:
                        final_answer.append(data['text'])
                except json.JSONDecodeError:
                    continue
        
        return "".join(final_answer) if final_answer else "Agent returned no text."

    except Exception as e:
        return f"Connection error: {str(e)}"
$$;

-- Usage: SELECT call_cortex_agent('Your question here');
