select id, device_name, assigned_cert, hardware_fingerprint, enabled, compliant, created_at
from nix.machines
where device_name = ?;
