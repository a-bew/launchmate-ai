class AppException(Exception):
    def __init__(self, status_code: int, error_code: str, message: str, field: str = None):
        self.status_code = status_code
        self.error_code = error_code
        self.message = message
        self.field = field

class LockedSectionError(AppException):
    def __init__(self, section: str):
        super().__init__(403, "forbidden", f"Section {section} is locked. Unlock before editing.", field=section)

class ConflictError(AppException):
    def __init__(self, message: str):
        super().__init__(409, "conflict", message)

class NotFoundError(AppException):
    def __init__(self, resource: str, id: str):
        super().__init__(404, "not_found", f"{resource} not found: {id}")

class ValidationError(AppException):
    def __init__(self, message: str, field: str = None):
        super().__init__(422, "validation_error", message, field=field)
