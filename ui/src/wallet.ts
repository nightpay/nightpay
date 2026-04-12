export type NightpayNetwork = 'preprod' | 'mainnet';
export type FundingMode = 'backend' | 'midnight' | 'cardano';
export type NetworkSource = 'bridge' | 'env' | 'default';
export type CardanoNetworkLabel = 'mainnet' | 'testnet' | 'unknown';

export type MidnightWalletProvider = {
  name?: string;
  rdns?: string;
  apiVersion?: string;
  connect?: (networkId: string) => Promise<unknown>;
  enable?: () => Promise<unknown>;
};

export type CardanoWalletProvider = {
  name?: string;
  apiVersion?: string;
  icon?: string;
  enable?: () => Promise<unknown>;
};

export type WalletWindowShape = {
  midnight?: Record<string, unknown>;
  cardano?: Record<string, unknown>;
};

export type MidnightWalletDescriptor = {
  id: string;
  name: string;
  rdns: string;
  apiVersion: string;
  supportsConnect: boolean;
  supportsEnable: boolean;
  provider: MidnightWalletProvider;
};

export type CardanoWalletDescriptor = {
  id: string;
  name: string;
  apiVersion: string;
  supportsEnable: boolean;
  provider: CardanoWalletProvider;
};

export type WalletDiagnostics = {
  midnight: MidnightWalletDescriptor[];
  cardano: CardanoWalletDescriptor[];
  preferredMidnightId?: string;
  preferredCardanoId?: string;
};

export type ResolvedNetwork = {
  network: NightpayNetwork;
  source: NetworkSource;
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

function isLaceLike(id: string, name: string, rdns?: string): boolean {
  return /lace/i.test(id) || /lace/i.test(name) || /lace/i.test(rdns ?? '');
}

function normalizeNetwork(value: string | null | undefined): NightpayNetwork | null {
  const normalized = (value ?? '').trim().toLowerCase();
  if (normalized === 'mainnet') return 'mainnet';
  if (normalized === 'preprod') return 'preprod';
  return null;
}

export function resolveRuntimeNetwork(params: {
  bridgeNetwork?: string | null;
  envNetwork?: string | null;
}): ResolvedNetwork {
  const bridge = normalizeNetwork(params.bridgeNetwork);
  if (bridge) {
    return { network: bridge, source: 'bridge' };
  }
  const env = normalizeNetwork(params.envNetwork);
  if (env) {
    return { network: env, source: 'env' };
  }
  return { network: 'preprod', source: 'default' };
}

export function collectWalletDiagnostics(walletWindow: WalletWindowShape): WalletDiagnostics {
  const midnightEntries = isRecord(walletWindow.midnight) ? Object.entries(walletWindow.midnight) : [];
  const cardanoEntries = isRecord(walletWindow.cardano) ? Object.entries(walletWindow.cardano) : [];

  const midnight = midnightEntries
    .filter(([, value]) => isRecord(value))
    .map(([id, value]) => {
      const provider = value as MidnightWalletProvider;
      const name = typeof provider.name === 'string' && provider.name.trim() ? provider.name : id;
      const rdns = typeof provider.rdns === 'string' ? provider.rdns : '';
      const apiVersion = typeof provider.apiVersion === 'string' ? provider.apiVersion : '';
      return {
        id,
        name,
        rdns,
        apiVersion,
        supportsConnect: typeof provider.connect === 'function',
        supportsEnable: typeof provider.enable === 'function',
        provider,
      } satisfies MidnightWalletDescriptor;
    });

  const cardano = cardanoEntries
    .filter(([, value]) => isRecord(value))
    .map(([id, value]) => {
      const provider = value as CardanoWalletProvider;
      const name = typeof provider.name === 'string' && provider.name.trim() ? provider.name : id;
      const apiVersion = typeof provider.apiVersion === 'string' ? provider.apiVersion : '';
      return {
        id,
        name,
        apiVersion,
        supportsEnable: typeof provider.enable === 'function',
        provider,
      } satisfies CardanoWalletDescriptor;
    });

  const preferredMidnightId =
    midnight.find((wallet) => isLaceLike(wallet.id, wallet.name, wallet.rdns))?.id ?? midnight[0]?.id;
  const preferredCardanoId =
    cardano.find((wallet) => isLaceLike(wallet.id, wallet.name))?.id ?? cardano[0]?.id;

  return {
    midnight,
    cardano,
    preferredMidnightId,
    preferredCardanoId,
  };
}

function pickById<T extends { id: string }>(items: T[], preferredId?: string): T | undefined {
  if (preferredId) {
    const byId = items.find((item) => item.id === preferredId);
    if (byId) return byId;
  }
  return items[0];
}

export async function connectMidnightWallet(
  walletWindow: WalletWindowShape,
  network: NightpayNetwork,
  preferredId?: string,
): Promise<{ walletId: string; walletLabel: string; apiVersion: string }> {
  const diagnostics = collectWalletDiagnostics(walletWindow);
  const selected = pickById(diagnostics.midnight, preferredId ?? diagnostics.preferredMidnightId);

  if (!selected) {
    const hasCardanoLace = diagnostics.cardano.some((wallet) => isLaceLike(wallet.id, wallet.name));
    if (hasCardanoLace) {
      throw new Error(
        'Cardano Lace was detected, but Midnight wallet provider is missing (`window.midnight`). Enable Midnight support and dApp access in Lace, then reload this page.',
      );
    }
    throw new Error(
      'No Midnight wallet provider detected (`window.midnight`). If Lace is installed, allow this site in extension settings and reload.',
    );
  }

  const provider = selected.provider;
  if (typeof provider.connect === 'function') {
    await provider.connect(network);
  } else if (typeof provider.enable === 'function') {
    await provider.enable();
  } else {
    throw new Error(`Wallet "${selected.id}" does not expose connect() or enable().`);
  }

  return {
    walletId: selected.id,
    walletLabel: selected.name || selected.id,
    apiVersion: selected.apiVersion,
  };
}

export async function connectCardanoWallet(
  walletWindow: WalletWindowShape,
  preferredId?: string,
): Promise<{ walletId: string; walletLabel: string; apiVersion: string; networkId: number | null }> {
  const diagnostics = collectWalletDiagnostics(walletWindow);
  const selected = pickById(diagnostics.cardano, preferredId ?? diagnostics.preferredCardanoId);
  if (!selected) {
    throw new Error(
      'No Cardano wallet provider detected (`window.cardano`). Install Lace or another CIP-30 wallet and reload.',
    );
  }

  const provider = selected.provider;
  if (typeof provider.enable !== 'function') {
    throw new Error(`Wallet "${selected.id}" does not expose enable().`);
  }

  const enabled = await provider.enable();
  let networkId: number | null = null;
  if (isRecord(enabled) && typeof enabled.getNetworkId === 'function') {
    const maybeNetworkId = await enabled.getNetworkId();
    networkId = typeof maybeNetworkId === 'number' ? maybeNetworkId : null;
  }

  return {
    walletId: selected.id,
    walletLabel: selected.name || selected.id,
    apiVersion: selected.apiVersion,
    networkId,
  };
}

export function cardanoNetworkLabel(networkId: number | null): CardanoNetworkLabel {
  if (networkId === 1) return 'mainnet';
  if (networkId === 0) return 'testnet';
  return 'unknown';
}

export function isCardanoNetworkCompatible(expected: NightpayNetwork, networkId: number | null): boolean | null {
  if (networkId === null) return null;
  return expected === 'mainnet' ? networkId === 1 : networkId === 0;
}

