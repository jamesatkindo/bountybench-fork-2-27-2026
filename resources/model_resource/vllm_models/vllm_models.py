import os
from datetime import datetime
from typing import List

from openai import OpenAI

from resources.model_resource.model_provider import ModelProvider
from resources.model_resource.model_response import ModelResponse
from utils.logger import get_main_logger

logger = get_main_logger(__name__)


class VLLMModels(ModelProvider):
    """
    Provider for vLLM servers using the OpenAI-compatible chat completions API.

    Usage: --model vllm/<model-name-on-server>
    Env vars:
        VLLM_BASE_URL  - e.g. http://localhost:8000/v1  (required)
        VLLM_API_KEY   - defaults to "dummy" (vLLM doesn't require a real key)
    """

    def __init__(self):
        self.client = self.create_client()

    @classmethod
    def _api_key(cls) -> str:
        return os.getenv("VLLM_API_KEY", "dummy")

    def create_client(self) -> OpenAI:
        base_url = os.getenv("VLLM_BASE_URL")
        if not base_url:
            raise ValueError(
                "VLLM_BASE_URL environment variable is not set. "
                "Set it to your vLLM server endpoint, e.g. http://localhost:8000/v1"
            )
        return OpenAI(api_key=self._api_key(), base_url=base_url)

    def request(
        self,
        model: str,
        message: str,
        temperature: float,
        max_tokens: int,
        stop_sequences: List[str],
    ) -> ModelResponse:
        # Strip "vllm/" prefix
        if "/" in model:
            model = model.split("/", 1)[1]

        start_time = datetime.now()
        status_code = None

        try:
            response = self.client.chat.completions.create(
                model=model,
                messages=[{"role": "user", "content": message}],
                temperature=temperature,
                max_tokens=max_tokens,
                stop=stop_sequences if stop_sequences else None,
            )

            if hasattr(response, "response") and hasattr(
                response.response, "status_code"
            ):
                status_code = response.response.status_code

            end_time = datetime.now()
            duration_ms = (end_time - start_time).total_seconds() * 1000

            return ModelResponse(
                content=response.choices[0].message.content,
                input_tokens=response.usage.prompt_tokens if response.usage else 0,
                output_tokens=response.usage.completion_tokens if response.usage else 0,
                time_taken_in_ms=duration_ms,
                status_code=status_code,
            )
        except Exception as e:
            try:
                if hasattr(e, "status_code"):
                    status_code = e.status_code
                elif hasattr(e, "response") and hasattr(e.response, "status_code"):
                    status_code = e.response.status_code
            except:
                pass
            if status_code is not None:
                e.status_code = status_code
            raise

    def tokenize(self, model: str, message: str) -> List[int]:
        # Approximate tokenization (~4 chars per token)
        return list(range(len(message) // 4))

    def decode(self, model: str, tokens: List[int]) -> str:
        raise NotImplementedError("Token decoding not supported for vLLM models")

    def get_num_tokens(self, model: str, message: str) -> int:
        # Approximate (~4 chars per token)
        return len(message) // 4
