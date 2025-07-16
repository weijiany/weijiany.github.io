FROM python:3.10.18-alpine3.22
WORKDIR /app
COPY pyproject.toml /app/pyproject.toml
COPY poetry.lock /app/poetry.lock
RUN pip install poetry
RUN poetry install --no-root
ENTRYPOINT ["sh", "-c"]
