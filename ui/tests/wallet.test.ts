import { describe, expect, it, vi } from 'vitest';
import {
  cardanoNetworkLabel,
  collectWalletDiagnostics,
  connectCardanoWallet,
  connectMidnightWallet,
  isCardanoNetworkCompatible,
  resolveRuntimeNetwork,
} from '../src/wallet.ts';

describe('resolveRuntimeNetwork', () => {
  it('prefers bridge network over env', () => {
    expect(resolveRuntimeNetwork({ bridgeNetwork: 'mainnet', envNetwork: 'preprod' })).toEqual({
      network: 'mainnet',
      source: 'bridge',
    });
  });

  it('falls back to env network', () => {
    expect(resolveRuntimeNetwork({ envNetwork: 'mainnet' })).toEqual({
      network: 'mainnet',
      source: 'env',
    });
  });

  it('defaults to preprod when unset', () => {
    expect(resolveRuntimeNetwork({})).toEqual({
      network: 'preprod',
      source: 'default',
    });
  });
});

describe('collectWalletDiagnostics', () => {
  it('handles empty providers', () => {
    expect(collectWalletDiagnostics({})).toEqual({
      midnight: [],
      cardano: [],
      preferredMidnightId: undefined,
      preferredCardanoId: undefined,
    });
  });

  it('detects cardano-only lace provider', () => {
    const diagnostics = collectWalletDiagnostics({
      cardano: {
        lace: {
          name: 'Lace',
          apiVersion: '1.0.0',
          enable: async () => ({}),
        },
      },
    });
    expect(diagnostics.cardano).toHaveLength(1);
    expect(diagnostics.preferredCardanoId).toBe('lace');
    expect(diagnostics.midnight).toHaveLength(0);
  });

  it('selects midnight lace by name/rdns among many providers', () => {
    const diagnostics = collectWalletDiagnostics({
      midnight: {
        otherWallet: { name: 'Other', connect: async () => ({}) },
        id1: { name: 'Midnight Lace', rdns: 'io.lace.wallet', connect: async () => ({}) },
      },
    });
    expect(diagnostics.preferredMidnightId).toBe('id1');
  });

  it('falls back to first midnight provider if no lace marker exists', () => {
    const diagnostics = collectWalletDiagnostics({
      midnight: {
        firstWallet: { name: 'First', connect: async () => ({}) },
        secondWallet: { name: 'Second', connect: async () => ({}) },
      },
    });
    expect(diagnostics.preferredMidnightId).toBe('firstWallet');
  });

  it('ignores non-object injected values', () => {
    const diagnostics = collectWalletDiagnostics({
      midnight: {
        bad: true,
        good: { name: 'Lace', connect: async () => ({}) },
      } as unknown as Record<string, unknown>,
      cardano: {
        nope: 'x',
      } as unknown as Record<string, unknown>,
    });
    expect(diagnostics.midnight).toHaveLength(1);
    expect(diagnostics.cardano).toHaveLength(0);
  });
});

describe('connectMidnightWallet', () => {
  it('connects using connect(networkId) when available', async () => {
    const connect = vi.fn(async () => ({}));
    const result = await connectMidnightWallet(
      {
        midnight: {
          lace: { name: 'Lace', apiVersion: '4.0.1', connect },
        },
      },
      'preprod',
    );
    expect(connect).toHaveBeenCalledWith('preprod');
    expect(result.walletId).toBe('lace');
  });

  it('falls back to enable() when connect() is unavailable', async () => {
    const enable = vi.fn(async () => ({}));
    const result = await connectMidnightWallet(
      {
        midnight: {
          mnLace: { name: 'Legacy Lace', enable },
        },
      },
      'preprod',
    );
    expect(enable).toHaveBeenCalled();
    expect(result.walletId).toBe('mnLace');
  });

  it('reports cardano-only lace as missing midnight provider', async () => {
    await expect(
      connectMidnightWallet(
        {
          cardano: {
            lace: { name: 'Lace', enable: async () => ({}) },
          },
        },
        'preprod',
      ),
    ).rejects.toThrow('Cardano Lace was detected, but Midnight wallet provider is missing');
  });

  it('throws for provider without connect/enable', async () => {
    await expect(
      connectMidnightWallet(
        {
          midnight: {
            lace: { name: 'Lace' },
          },
        },
        'preprod',
      ),
    ).rejects.toThrow('does not expose connect() or enable()');
  });
});

describe('connectCardanoWallet', () => {
  it('connects via enable and reads network id', async () => {
    const enable = vi.fn(async () => ({
      getNetworkId: async () => 0,
    }));
    const result = await connectCardanoWallet({
      cardano: {
        lace: { name: 'Lace', apiVersion: '1.9.0', enable },
      },
    });
    expect(enable).toHaveBeenCalled();
    expect(result.walletId).toBe('lace');
    expect(result.networkId).toBe(0);
  });

  it('throws when no cardano provider exists', async () => {
    await expect(connectCardanoWallet({})).rejects.toThrow('No Cardano wallet provider detected');
  });

  it('throws when cardano provider lacks enable()', async () => {
    await expect(
      connectCardanoWallet({
        cardano: {
          lace: { name: 'Lace' },
        },
      }),
    ).rejects.toThrow('does not expose enable()');
  });
});

describe('cardano network compatibility', () => {
  it('maps network id labels', () => {
    expect(cardanoNetworkLabel(1)).toBe('mainnet');
    expect(cardanoNetworkLabel(0)).toBe('testnet');
    expect(cardanoNetworkLabel(null)).toBe('unknown');
  });

  it('validates expected network', () => {
    expect(isCardanoNetworkCompatible('mainnet', 1)).toBe(true);
    expect(isCardanoNetworkCompatible('mainnet', 0)).toBe(false);
    expect(isCardanoNetworkCompatible('preprod', 0)).toBe(true);
    expect(isCardanoNetworkCompatible('preprod', 1)).toBe(false);
    expect(isCardanoNetworkCompatible('preprod', null)).toBe(null);
  });
});

