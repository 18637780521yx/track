import os


class Settings:
    addr: str = os.getenv("ADDR", ":8080")
    database_url: str = os.getenv(
        "DATABASE_URL",
        "postgres://track:track@localhost:5432/track?sslmode=disable",
    )

    @property
    def host(self) -> str:
        addr = self.addr
        if addr.startswith(":"):
            return "0.0.0.0"
        if ":" in addr:
            return addr.rsplit(":", 1)[0] or "0.0.0.0"
        return "0.0.0.0"

    @property
    def port(self) -> int:
        addr = self.addr
        if addr.startswith(":"):
            return int(addr[1:] or "8080")
        if ":" in addr:
            return int(addr.rsplit(":", 1)[1])
        return 8080

    @property
    def asyncpg_dsn(self) -> str:
        # asyncpg uses postgresql:// and does not accept libpq sslmode query
        url = self.database_url
        if url.startswith("postgres://"):
            url = "postgresql://" + url[len("postgres://") :]
        if "?" in url:
            base, query = url.split("?", 1)
            parts = [
                p
                for p in query.split("&")
                if p and not p.startswith("sslmode=")
            ]
            url = base + (("?" + "&".join(parts)) if parts else "")
        return url


settings = Settings()
