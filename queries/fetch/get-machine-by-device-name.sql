select id, deviceName, assignedCert, hardwareFingerprint, enabled, compliant, createdAt
from nix.machines
where deviceName = ?;
