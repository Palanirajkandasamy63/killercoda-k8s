#!/bin/bash

echo "Waiting for the Polyphone baseline to finish spinning up..."
while [ ! -f /tmp/.setup-complete ]; do
  sleep 3
  echo -n "."
done
echo ""
echo ""
echo "cdr-writer (cdr-storage) has a replica stuck — and both replicas want the"
echo "same node. Start with the Pods and the claim:"
echo ""
echo "  kubectl get pods -n cdr-storage -o wide"
echo "  kubectl get pvc -n cdr-storage"
echo ""
