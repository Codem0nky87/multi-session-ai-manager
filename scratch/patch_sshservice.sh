sed -i '' -e 's/let knownHosts: KnownHostsStore/let knownHosts: KnownHostsStore\n    var isWindows: Bool = false/' app/MultiSessionAIManager/Core/SSHService.swift
