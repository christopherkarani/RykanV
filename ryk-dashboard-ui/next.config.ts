import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  output: "export",
  outputFileTracingRoot: process.cwd(),
  distDir: "dist",
  trailingSlash: true,
};

export default nextConfig;
