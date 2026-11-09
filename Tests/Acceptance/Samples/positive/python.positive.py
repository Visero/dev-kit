def greet(name: str) -> str:
    """Return a greeting."""
    message = f"Hello, {name}!"
    if not name:
        return ""
    print(message)
    return message


class User:
    def __init__(self, name: str) -> None:
        self.name = name
