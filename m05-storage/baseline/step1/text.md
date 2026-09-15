# Step 1 — A volume is a directory

A volume is a directory, possibly with data in it, that the containers in a Pod can reach. Two declarations produce one: `.spec.volumes` provides the volume, and `.spec.containers[*].volumeMounts` places it inside a container. The two halves join by name.

## Read the volumes a fleet Pod already has

```bash
POD=$(kubectl get pods -n cdr-storage -l app=cdr-writer -o jsonpath='{.items[0].metadata.name}')
kubectl describe pod "$POD" -n cdr-storage
```{{exec}}

Find the `Volumes:` block near the bottom. The volume named `data` has `Type: PersistentVolumeClaim` and `ClaimName: cdr-data`. Above it, the container's `Mounts:` line shows where that volume lands: /data. One name, two halves.

## Provide an emptyDir and share it between containers

Most volume types are ephemeral — they live and die with the Pod. `emptyDir` is the simplest one. Create a Pod with two containers that mount the same `emptyDir` at different paths:

```bash
kubectl apply -f - <<'YAML'
apiVersion: v1
kind: Pod
metadata: { name: vol-demo, namespace: cdr-storage }
spec:
  volumes:
    - name: scratch
      emptyDir: {}
  containers:
    - name: writer
      image: nginx:1.25
      command: ["sleep", "3600"]
      volumeMounts: [{ name: scratch, mountPath: /work }]
    - name: reader
      image: nginx:1.25
      command: ["sleep", "3600"]
      volumeMounts: [{ name: scratch, mountPath: /shared }]
YAML
kubectl wait --for=condition=Ready pod vol-demo -n cdr-storage --timeout=60s
```{{exec}}

Write from one container, read from the other:

```bash
kubectl exec -n cdr-storage vol-demo -c writer -- sh -c 'echo scratch-note > /work/note'
kubectl exec -n cdr-storage vol-demo -c reader -- cat /shared/note
```{{exec}}

The `reader` container sees the file at /shared that `writer` created at /work. One directory, two mount paths, because both containers mount the same volume.

## Prove the emptyDir dies with the Pod

```bash
kubectl delete pod vol-demo -n cdr-storage
kubectl apply -f - <<'YAML'
apiVersion: v1
kind: Pod
metadata: { name: vol-demo, namespace: cdr-storage }
spec:
  volumes:
    - name: scratch
      emptyDir: {}
  containers:
    - name: reader
      image: nginx:1.25
      command: ["sleep", "3600"]
      volumeMounts: [{ name: scratch, mountPath: /shared }]
YAML
kubectl wait --for=condition=Ready pod vol-demo -n cdr-storage --timeout=60s
kubectl exec -n cdr-storage vol-demo -c reader -- ls -la /shared
```{{exec}}

The directory is empty. The file went with the old Pod, because an `emptyDir` lasts exactly as long as the Pod that holds it. ConfigMap, Secret and downwardAPI volumes behave the same way (M03 covered the first two).

Clean up:

```bash
kubectl delete pod vol-demo -n cdr-storage
```{{exec}}

Only one volume type survives its Pod: `persistentVolumeClaim`. That is the `data` volume on `cdr-writer`, and the subject of the next four steps.
