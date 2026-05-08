(function initMaintenanceStorage(global) {
  "use strict";

  var STORAGE_KEY = "parallelSmokeMaintenanceRequests";
  var STATUS_OPTIONS = Object.freeze([
    "new",
    "triaged",
    "in_progress",
    "blocked",
    "completed",
  ]);
  var PRIORITY_OPTIONS = Object.freeze([
    "low",
    "medium",
    "high",
    "critical",
  ]);
  var STATUS_LABELS = Object.freeze({
    new: "New",
    triaged: "Triaged",
    in_progress: "In Progress",
    blocked: "Blocked",
    completed: "Completed",
  });
  var FIELD_LIMITS = deepFreeze({
    title: { min: 5, max: 80 },
    assetName: { min: 2, max: 60 },
    location: { min: 2, max: 60 },
    requestedBy: { min: 2, max: 40 },
    description: { min: 0, max: 200 },
  });
  var SEED_REQUESTS = [
    {
      id: "seed-hvac-001",
      title: "Main lobby AC not cooling",
      assetName: "Lobby HVAC Unit",
      location: "Building A - Lobby",
      requestedBy: "Reception Desk",
      priority: "high",
      status: "new",
      description: "Airflow is present but the unit has been blowing warm air since opening.",
      createdAt: "2026-05-07T08:15:00.000Z",
    },
    {
      id: "seed-lift-002",
      title: "Freight elevator inspection follow-up",
      assetName: "Freight Elevator 2",
      location: "Warehouse South",
      requestedBy: "Shift Lead",
      priority: "medium",
      status: "triaged",
      description: "Inspection flagged an intermittent door-close delay during unload windows.",
      createdAt: "2026-05-06T23:40:00.000Z",
    },
    {
      id: "seed-printer-003",
      title: "Shipping label printer jam recurring",
      assetName: "Label Printer 7",
      location: "Dispatch Counter",
      requestedBy: "Dispatch Team",
      priority: "low",
      status: "in_progress",
      description: "Paper feed stalls after every third label batch and needs manual reset.",
      createdAt: "2026-05-05T05:05:00.000Z",
    },
    {
      id: "seed-pump-004",
      title: "Boiler room condensate pump alarm",
      assetName: "Condensate Pump",
      location: "Utility Basement",
      requestedBy: "Facilities On Call",
      priority: "critical",
      status: "blocked",
      description: "Alarm is active, but replacement seals are still waiting on delivery.",
      createdAt: "2026-05-04T18:30:00.000Z",
    },
    {
      id: "seed-door-005",
      title: "Server room badge reader reset complete",
      assetName: "Badge Reader 3",
      location: "Server Room Entry",
      requestedBy: "IT Operations",
      priority: "medium",
      status: "completed",
      description: "Reader firmware was reloaded and access checks passed after maintenance.",
      createdAt: "2026-05-03T02:10:00.000Z",
    },
  ];
  var cachedRequests = null;

  function deepFreeze(value) {
    Object.keys(value).forEach(function freezeKey(key) {
      var nested = value[key];
      if (nested && typeof nested === "object" && !Object.isFrozen(nested)) {
        deepFreeze(nested);
      }
    });

    return Object.freeze(value);
  }

  function createNormalizedError(code, message, details) {
    var error = new Error(message || code);
    error.name = "MaintenanceStorageError";
    error.code = code;
    if (details !== undefined) {
      error.details = details;
    }
    return error;
  }

  function cloneRequest(request) {
    return {
      id: request.id,
      title: request.title,
      assetName: request.assetName,
      location: request.location,
      requestedBy: request.requestedBy,
      priority: request.priority,
      status: request.status,
      description: request.description,
      createdAt: request.createdAt,
    };
  }

  function cloneRequests(requests) {
    return requests.map(cloneRequest);
  }

  function setCachedRequests(requests) {
    cachedRequests = cloneRequests(requests);
    return cloneRequests(cachedRequests);
  }

  function resetCachedRequests() {
    cachedRequests = [];
  }

  function normalizeString(value) {
    return typeof value === "string" ? value.trim() : "";
  }

  function normalizeEnumValue(value) {
    return normalizeString(value).toLowerCase();
  }

  function getLocalStorage() {
    if (!global || !global.localStorage) {
      throw createNormalizedError(
        "storage_unavailable",
        "localStorage is unavailable in this environment."
      );
    }
    return global.localStorage;
  }

  function getStoredValue() {
    try {
      return getLocalStorage().getItem(STORAGE_KEY);
    } catch (error) {
      resetCachedRequests();
      throw createNormalizedError(
        "storage_unavailable",
        "Failed to read from localStorage.",
        error
      );
    }
  }

  function setStoredValue(serializedRequests) {
    try {
      getLocalStorage().setItem(STORAGE_KEY, serializedRequests);
    } catch (error) {
      throw createNormalizedError(
        "storage_unavailable",
        "Failed to write to localStorage.",
        error
      );
    }
  }

  function validateLength(fieldName, value, limits, errors) {
    if (value.length < limits.min || value.length > limits.max) {
      errors.push(
        fieldName +
          " must be between " +
          limits.min +
          " and " +
          limits.max +
          " characters."
      );
    }
  }

  function assertAllowedEnum(fieldName, value, allowedValues, errorCode) {
    if (allowedValues.indexOf(value) === -1) {
      throw createNormalizedError(
        errorCode,
        fieldName + " must be one of: " + allowedValues.join(", ") + "."
      );
    }
  }

  function normalizeDraft(draft) {
    if (!draft || typeof draft !== "object" || Array.isArray(draft)) {
      throw createNormalizedError(
        "validation_failed",
        "Request draft must be a plain object."
      );
    }

    var normalized = {
      title: normalizeString(draft.title),
      assetName: normalizeString(draft.assetName),
      location: normalizeString(draft.location),
      requestedBy: normalizeString(draft.requestedBy),
      priority: normalizeEnumValue(draft.priority),
      description: normalizeString(draft.description),
    };
    var errors = [];

    validateLength("title", normalized.title, FIELD_LIMITS.title, errors);
    validateLength(
      "assetName",
      normalized.assetName,
      FIELD_LIMITS.assetName,
      errors
    );
    validateLength("location", normalized.location, FIELD_LIMITS.location, errors);
    validateLength(
      "requestedBy",
      normalized.requestedBy,
      FIELD_LIMITS.requestedBy,
      errors
    );
    validateLength(
      "description",
      normalized.description,
      FIELD_LIMITS.description,
      errors
    );

    if (PRIORITY_OPTIONS.indexOf(normalized.priority) === -1) {
      errors.push(
        "priority must be one of: " + PRIORITY_OPTIONS.join(", ") + "."
      );
    }

    if (errors.length > 0) {
      throw createNormalizedError(
        "validation_failed",
        "Request draft validation failed.",
        errors
      );
    }

    return normalized;
  }

  function normalizeRequestRecord(record, errorCode) {
    if (!record || typeof record !== "object" || Array.isArray(record)) {
      throw createNormalizedError(errorCode, "Stored request must be an object.");
    }

    var normalized = {
      id: normalizeString(record.id),
      title: normalizeString(record.title),
      assetName: normalizeString(record.assetName),
      location: normalizeString(record.location),
      requestedBy: normalizeString(record.requestedBy),
      priority: normalizeEnumValue(record.priority),
      status: normalizeEnumValue(record.status),
      description: normalizeString(record.description),
      createdAt: normalizeString(record.createdAt),
    };
    var errors = [];

    if (!normalized.id) {
      errors.push("id is required.");
    }

    validateLength("title", normalized.title, FIELD_LIMITS.title, errors);
    validateLength(
      "assetName",
      normalized.assetName,
      FIELD_LIMITS.assetName,
      errors
    );
    validateLength("location", normalized.location, FIELD_LIMITS.location, errors);
    validateLength(
      "requestedBy",
      normalized.requestedBy,
      FIELD_LIMITS.requestedBy,
      errors
    );
    validateLength(
      "description",
      normalized.description,
      FIELD_LIMITS.description,
      errors
    );

    if (PRIORITY_OPTIONS.indexOf(normalized.priority) === -1) {
      errors.push("priority is invalid.");
    }

    if (STATUS_OPTIONS.indexOf(normalized.status) === -1) {
      errors.push("status is invalid.");
    }

    if (!normalized.createdAt || Number.isNaN(Date.parse(normalized.createdAt))) {
      errors.push("createdAt must be a valid ISO 8601 string.");
    }

    if (errors.length > 0) {
      throw createNormalizedError(errorCode, "Stored request is invalid.", errors);
    }

    return normalized;
  }

  function parseStoredRequests(rawValue) {
    var parsed;

    try {
      parsed = JSON.parse(rawValue);
    } catch (error) {
      resetCachedRequests();
      throw createNormalizedError(
        "storage_corrupted",
        "Stored requests contain invalid JSON.",
        error
      );
    }

    if (!Array.isArray(parsed)) {
      resetCachedRequests();
      throw createNormalizedError(
        "storage_corrupted",
        "Stored requests must be an array."
      );
    }

    try {
      return parsed.map(function mapRequest(record) {
        return normalizeRequestRecord(record, "storage_corrupted");
      });
    } catch (error) {
      resetCachedRequests();

      if (error && error.code === "storage_corrupted") {
        throw error;
      }

      throw createNormalizedError(
        "storage_corrupted",
        "Stored requests contain invalid records.",
        error
      );
    }
  }

  function persistRequests(requests) {
    var normalizedRequests = requests.map(function mapRequest(record) {
      return normalizeRequestRecord(record, "validation_failed");
    });
    var serializedRequests = JSON.stringify(normalizedRequests);

    setStoredValue(serializedRequests);
    return setCachedRequests(normalizedRequests);
  }

  function getSeedRequests() {
    return SEED_REQUESTS.map(function mapSeed(record) {
      return normalizeRequestRecord(record, "validation_failed");
    });
  }

  function readRequests(options) {
    var rawValue = getStoredValue();
    var shouldSeedIfMissing = Boolean(options && options.seedIfMissing);

    if (rawValue === null) {
      if (!shouldSeedIfMissing) {
        resetCachedRequests();
        return [];
      }

      return persistRequests(getSeedRequests());
    }

    var parsedRequests = parseStoredRequests(rawValue);
    return setCachedRequests(parsedRequests);
  }

  function resolveRequestSource(requests) {
    if (requests === undefined) {
      if (cachedRequests !== null) {
        return cloneRequests(cachedRequests);
      }
      return cloneRequests(getSeedRequests());
    }

    if (!Array.isArray(requests)) {
      throw createNormalizedError(
        "validation_failed",
        "Request list must be provided as an array."
      );
    }

    return requests.map(function mapRequest(record) {
      return normalizeRequestRecord(record, "validation_failed");
    });
  }

  function normalizeFilters(filters) {
    var nextFilters = filters || {};
    var normalized = {
      status:
        nextFilters.status === undefined
          ? "all"
          : normalizeEnumValue(nextFilters.status),
      priority:
        nextFilters.priority === undefined
          ? "all"
          : normalizeEnumValue(nextFilters.priority),
    };

    if (
      normalized.status !== "all" &&
      STATUS_OPTIONS.indexOf(normalized.status) === -1
    ) {
      throw createNormalizedError(
        "validation_failed",
        "status filter must be all or a known status."
      );
    }

    if (
      normalized.priority !== "all" &&
      PRIORITY_OPTIONS.indexOf(normalized.priority) === -1
    ) {
      throw createNormalizedError(
        "validation_failed",
        "priority filter must be all or a known priority."
      );
    }

    return normalized;
  }

  function createRequestId() {
    return "request-" + Date.now() + "-" + Math.random().toString(36).slice(2, 8);
  }

  function loadRequests() {
    return readRequests({ seedIfMissing: true });
  }

  function addRequest(draft) {
    var normalizedDraft = normalizeDraft(draft);
    var existingRequests = readRequests({ seedIfMissing: true });
    var nextRequest = {
      id: createRequestId(),
      title: normalizedDraft.title,
      assetName: normalizedDraft.assetName,
      location: normalizedDraft.location,
      requestedBy: normalizedDraft.requestedBy,
      priority: normalizedDraft.priority,
      status: "new",
      description: normalizedDraft.description,
      createdAt: new Date().toISOString(),
    };

    persistRequests([nextRequest].concat(existingRequests));

    return cloneRequest(nextRequest);
  }

  function updateRequestStatus(requestId, nextStatus) {
    var normalizedRequestId = normalizeString(requestId);
    var normalizedStatus = normalizeEnumValue(nextStatus);

    if (!normalizedRequestId) {
      throw createNormalizedError(
        "request_not_found",
        "A known request id is required."
      );
    }

    assertAllowedEnum(
      "nextStatus",
      normalizedStatus,
      STATUS_OPTIONS,
      "validation_failed"
    );

    var existingRequests = readRequests({ seedIfMissing: false });
    var requestFound = false;
    var updatedRequests = existingRequests.map(function updateRequest(request) {
      if (request.id !== normalizedRequestId) {
        return request;
      }

      requestFound = true;

      return {
        id: request.id,
        title: request.title,
        assetName: request.assetName,
        location: request.location,
        requestedBy: request.requestedBy,
        priority: request.priority,
        status: normalizedStatus,
        description: request.description,
        createdAt: request.createdAt,
      };
    });

    if (!requestFound) {
      throw createNormalizedError(
        "request_not_found",
        "The request id does not exist."
      );
    }

    return persistRequests(updatedRequests);
  }

  function getFilteredRequests(filters, requests) {
    var normalizedFilters = normalizeFilters(filters);
    var sourceRequests = resolveRequestSource(requests);

    return sourceRequests.filter(function matchesFilters(request) {
      var matchesStatus =
        normalizedFilters.status === "all" ||
        request.status === normalizedFilters.status;
      var matchesPriority =
        normalizedFilters.priority === "all" ||
        request.priority === normalizedFilters.priority;

      return matchesStatus && matchesPriority;
    });
  }

  function getStatusSummary(requests) {
    var sourceRequests = resolveRequestSource(requests);

    return STATUS_OPTIONS.map(function createSummary(status) {
      var count = sourceRequests.reduce(function countRequests(total, request) {
        return request.status === status ? total + 1 : total;
      }, 0);

      return {
        status: status,
        label: STATUS_LABELS[status],
        count: count,
      };
    });
  }

  global.MaintenanceStorage = Object.freeze({
    STORAGE_KEY: STORAGE_KEY,
    FIELD_LIMITS: FIELD_LIMITS,
    STATUS_OPTIONS: STATUS_OPTIONS,
    PRIORITY_OPTIONS: PRIORITY_OPTIONS,
    loadRequests: loadRequests,
    addRequest: addRequest,
    updateRequestStatus: updateRequestStatus,
    getFilteredRequests: getFilteredRequests,
    getStatusSummary: getStatusSummary,
  });
})(typeof window !== "undefined" ? window : globalThis);
