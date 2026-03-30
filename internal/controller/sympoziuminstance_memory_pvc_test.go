package controller

import (
	"context"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"

	sympoziumv1alpha1 "github.com/kasdk3/sympozium/api/v1alpha1"
)

// ---------------------------------------------------------------------------
// Test: PVC is created when instance has the "memory" SkillPack
// ---------------------------------------------------------------------------

func TestInstanceMemory_PVCCreatedWhenMemorySkillAttached(t *testing.T) {
	instance := &sympoziumv1alpha1.SympoziumInstance{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "mem-pvc-test",
			Namespace: "default",
		},
		Spec: sympoziumv1alpha1.SympoziumInstanceSpec{
			Agents: sympoziumv1alpha1.AgentsSpec{
				Default: sympoziumv1alpha1.AgentConfig{
					Model: "claude-sonnet-4-20250514",
				},
			},
			AuthRefs: []sympoziumv1alpha1.SecretRef{
				{Provider: "anthropic", Secret: "CLAUDE_TOKEN"},
			},
			Skills: []sympoziumv1alpha1.SkillRef{
				{SkillPackRef: "memory"},
			},
		},
	}

	r, cl := newInstanceTestReconciler(t, instance)

	_, err := r.Reconcile(context.Background(), ctrl.Request{
		NamespacedName: types.NamespacedName{Name: instance.Name, Namespace: "default"},
	})
	if err != nil {
		t.Fatalf("reconcile: %v", err)
	}

	// The PVC should exist.
	pvcName := "mem-pvc-test-memory-db"
	var pvc corev1.PersistentVolumeClaim
	if err := cl.Get(context.Background(), types.NamespacedName{Name: pvcName, Namespace: "default"}, &pvc); err != nil {
		t.Fatalf("PVC %q should exist: %v", pvcName, err)
	}

	// Verify labels.
	if pvc.Labels["sympozium.ai/instance"] != "mem-pvc-test" {
		t.Errorf("instance label = %q", pvc.Labels["sympozium.ai/instance"])
	}
	if pvc.Labels["sympozium.ai/component"] != "memory-db" {
		t.Errorf("component label = %q", pvc.Labels["sympozium.ai/component"])
	}

	// Verify access mode.
	if len(pvc.Spec.AccessModes) == 0 || pvc.Spec.AccessModes[0] != corev1.ReadWriteOnce {
		t.Errorf("access mode = %v, want ReadWriteOnce", pvc.Spec.AccessModes)
	}
}

// ---------------------------------------------------------------------------
// Test: PVC is NOT created when instance does not have the memory skill
// ---------------------------------------------------------------------------

func TestInstanceMemory_PVCNotCreatedWithoutMemorySkill(t *testing.T) {
	instance := &sympoziumv1alpha1.SympoziumInstance{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "no-mem-skill",
			Namespace: "default",
		},
		Spec: sympoziumv1alpha1.SympoziumInstanceSpec{
			Agents: sympoziumv1alpha1.AgentsSpec{
				Default: sympoziumv1alpha1.AgentConfig{
					Model: "gpt-4o",
				},
			},
			AuthRefs: []sympoziumv1alpha1.SecretRef{
				{Provider: "openai", Secret: "OPENAI_KEY"},
			},
			Skills: []sympoziumv1alpha1.SkillRef{
				{SkillPackRef: "k8s-ops"},
			},
		},
	}

	r, cl := newInstanceTestReconciler(t, instance)

	_, err := r.Reconcile(context.Background(), ctrl.Request{
		NamespacedName: types.NamespacedName{Name: instance.Name, Namespace: "default"},
	})
	if err != nil {
		t.Fatalf("reconcile: %v", err)
	}

	pvcName := "no-mem-skill-memory-db"
	var pvc corev1.PersistentVolumeClaim
	err = cl.Get(context.Background(), types.NamespacedName{Name: pvcName, Namespace: "default"}, &pvc)
	if err == nil {
		t.Fatalf("PVC %q should NOT exist when memory skill is not attached", pvcName)
	}
}

// ---------------------------------------------------------------------------
// Test: reconcile is idempotent when PVC already exists
// ---------------------------------------------------------------------------

func TestInstanceMemory_PVCAlreadyExists(t *testing.T) {
	instance := &sympoziumv1alpha1.SympoziumInstance{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "idempotent-pvc",
			Namespace: "default",
		},
		Spec: sympoziumv1alpha1.SympoziumInstanceSpec{
			Agents: sympoziumv1alpha1.AgentsSpec{
				Default: sympoziumv1alpha1.AgentConfig{
					Model: "claude-sonnet-4-20250514",
				},
			},
			AuthRefs: []sympoziumv1alpha1.SecretRef{
				{Provider: "anthropic", Secret: "CLAUDE_TOKEN"},
			},
			Skills: []sympoziumv1alpha1.SkillRef{
				{SkillPackRef: "memory"},
			},
		},
	}

	// Pre-create the PVC (simulates a previous reconcile).
	existingPVC := &corev1.PersistentVolumeClaim{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "idempotent-pvc-memory-db",
			Namespace: "default",
			Labels: map[string]string{
				"sympozium.ai/instance":  "idempotent-pvc",
				"sympozium.ai/component": "memory-db",
			},
		},
		Spec: corev1.PersistentVolumeClaimSpec{
			AccessModes: []corev1.PersistentVolumeAccessMode{corev1.ReadWriteOnce},
		},
	}

	r, cl := newInstanceTestReconciler(t, instance, existingPVC)

	// Reconcile should succeed (no error from duplicate create).
	_, err := r.Reconcile(context.Background(), ctrl.Request{
		NamespacedName: types.NamespacedName{Name: instance.Name, Namespace: "default"},
	})
	if err != nil {
		t.Fatalf("reconcile with existing PVC: %v", err)
	}

	// PVC should still exist.
	var pvc corev1.PersistentVolumeClaim
	if err := cl.Get(context.Background(), types.NamespacedName{Name: "idempotent-pvc-memory-db", Namespace: "default"}, &pvc); err != nil {
		t.Fatalf("PVC should still exist after idempotent reconcile: %v", err)
	}
}
