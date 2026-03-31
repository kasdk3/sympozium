package charts

import "embed"

// Sympozium embeds the Sympozium Helm chart from charts/sympozium/.
//
//go:embed all:sympozium
var Sympozium embed.FS
