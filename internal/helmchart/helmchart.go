// Package helmchart provides helpers for loading the embedded Sympozium Helm chart.
package helmchart

import (
	"fmt"
	"io/fs"

	"helm.sh/helm/v3/pkg/chart"
	"helm.sh/helm/v3/pkg/chart/loader"

	"github.com/sympozium-ai/sympozium/charts"
)

// Load returns the embedded Sympozium Helm chart, ready for use with the
// Helm SDK action package.
func Load() (*chart.Chart, error) {
	files, err := collectFiles("sympozium")
	if err != nil {
		return nil, fmt.Errorf("reading embedded chart: %w", err)
	}
	ch, err := loader.LoadFiles(files)
	if err != nil {
		return nil, fmt.Errorf("loading helm chart: %w", err)
	}
	return ch, nil
}

// collectFiles walks the embedded filesystem and returns chart files relative
// to the chart root.
func collectFiles(root string) ([]*loader.BufferedFile, error) {
	var files []*loader.BufferedFile
	err := fs.WalkDir(charts.Sympozium, root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}
		data, err := fs.ReadFile(charts.Sympozium, path)
		if err != nil {
			return err
		}
		// Strip the root prefix so paths are relative to the chart directory
		// (e.g. "sympozium/Chart.yaml" → "Chart.yaml").
		rel := path[len(root)+1:]
		files = append(files, &loader.BufferedFile{Name: rel, Data: data})
		return nil
	})
	return files, err
}
