import enum

class SectionLockStatus(str, enum.Enum):
    LOCKED = "locked"
    UNLOCKED = "unlocked"
    DRAFT = "draft"

class ProjectStatus(str, enum.Enum):
    IDEATION = "ideation"
    DRAFT = "draft"
    ACTIVE = "active"
    ARCHIVED = "archived"

class ProjectLockStatus(str, enum.Enum):
    LOCKED = "locked"
    UNLOCKED = "unlocked"

class VersionType(str, enum.Enum):
    VERSION = "version"
    BRANCH = "branch"

class ThreadStatus(str, enum.Enum):
    OPEN = "open"
    CLOSED = "closed"
    PROMOTED = "promoted"

class AmendmentSourceType(str, enum.Enum):
    THREAD = "thread"
    REFINEMENT = "refinement"

class AmendmentStatus(str, enum.Enum):
    PENDING = "pending_review"
    ACCEPTED = "accepted"
    REJECTED = "rejected"

class ProactiveStatus(str, enum.Enum):
    OPEN = "open"
    DISMISSED = "dismissed"
    SNOOZED = "snoozed"

class RefinementStatus(str, enum.Enum):
    PENDING = "pending_review"
    ACCEPTED = "accepted"
    REJECTED = "rejected"
