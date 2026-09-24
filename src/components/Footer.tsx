import { useState } from "react";

const GITHUB_URL = "https://github.com/melo-foundation/melo";
const DISCORD_URL = "https://discord.gg/T2jHMX6AcG";
const DONATE = [
  { coin: "BTC", address: "bc1qzpwsr4mkhq0pm0dnntnnta0asrjwnrezt0mvt9" },
  { coin: "ETH", address: "0x2c283673287396bBAAc8c471276Ab1673DF9074B" },
  { coin: "SOL", address: "EnRisDAKEgp9Sa7iJxfjG2KdSojCp32Up7DmEtXrMVRb" },
  { coin: "XMR", address: "86nuvmwbjd8697NcqdGVYy1wH8gpE7eXwRTYbpd6y6jzFgQTufgnxuJeTCN95uucH5VgRxupTp2XxWDm2UwkG26HRv3tnYD" },
];
const short = (a: string) => `${a.slice(0, 6)}…${a.slice(-5)}`;

export function Footer() {
  const [copied, setCopied] = useState<string | null>(null);
  const copy = (coin: string, address: string) => {
    navigator.clipboard?.writeText(address).then(() => {
      setCopied(coin);
      setTimeout(() => setCopied(null), 1500);
    }).catch(() => {});
  };
  return (
    <footer className="footer">
      <div className="container footer__inner">
        <div className="footer__links">
          <a href={GITHUB_URL} target="_blank" rel="noopener noreferrer">GitHub</a>
          <a href={`${GITHUB_URL}/releases`} target="_blank" rel="noopener noreferrer">Releases</a>
          <a href={`${GITHUB_URL}/issues`} target="_blank" rel="noopener noreferrer">Issues</a>
          <a href={DISCORD_URL} target="_blank" rel="noopener noreferrer">Discord</a>
        </div>
        <div className="footer__donate">
          <span className="footer__donate-label">Donate</span>
          {DONATE.map(({ coin, address }) => (
            <button key={coin} className="footer__donate-coin" onClick={() => copy(coin, address)} title={address}>
              {coin} <code>{copied === coin ? "Copied" : short(address)}</code>
            </button>
          ))}
        </div>
        <p className="footer__credit">© 2026 melo</p>
      </div>
    </footer>
  );
}
