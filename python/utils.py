import json
from typing import Dict, List, Tuple, Set

import requests


def get_jaeger_network_map(jaeger_base_url: str, lookback: str = "3600000") -> List[Dict]:
    """
    Fetch the dependency graph from Jaeger.

    :param jaeger_base_url: Base URL of the Jaeger UI/service, e.g., http://<host>:<port>
    :param lookback: Lookback window (e.g., "1h", "2h", "24h").
    :return: List of dependency edges as returned by Jaeger.
    :raises: Exception if the request fails.
    """
    # Jaeger expects 'lookback' as integer milliseconds
    url = f"{jaeger_base_url.rstrip('/')}/api/dependencies?lookback={lookback}"
    response = requests.get(url, timeout=10)
    if response.status_code != 200:
        raise Exception(
            f"Failed to fetch Jaeger dependencies: {response.status_code}, {response.text}"
        )

    payload = response.json()
    # Normalize payload to a list of dependency dicts
    if isinstance(payload, list):
        return payload
    if isinstance(payload, dict):
        if "data" in payload and isinstance(payload["data"], list):
            return payload["data"]
        if "dependencies" in payload and isinstance(payload["dependencies"], list):
            return payload["dependencies"]
    if isinstance(payload, str):
        try:
            parsed = json.loads(payload)
            if isinstance(parsed, list):
                return parsed
            if isinstance(parsed, dict) and "data" in parsed and isinstance(parsed["data"], list):
                return parsed["data"]
        except Exception:
            pass
    raise Exception("Unexpected Jaeger dependencies payload format")


def build_service_graph_edges(dependencies: List[Dict]) -> List[Tuple[str, str, int]]:
    """
    Convert Jaeger's dependency list to a list of (parent, child, call_count) edges.
    """
    edges: List[Tuple[str, str, int]] = []
    for item in dependencies:
        parent = item.get("parent")
        child = item.get("child")
        call_count = item.get("callCount", 0)
        if parent and child:
            edges.append((parent, child, call_count))
    return edges


def build_parent_child_map(edges: List[Tuple[str, str, int]]) -> Dict[str, Dict[str, int]]:
    """
    Build a dict mapping parent -> { child -> call_count }.
    """
    graph: Dict[str, Dict[str, int]] = {}
    for parent, child, call_count in edges:
        graph.setdefault(parent, {})[child] = graph.get(parent, {}).get(child, 0) + call_count
    return graph


def build_reverse_child_parent_map(edges: List[Tuple[str, str, int]]) -> Dict[str, Dict[str, int]]:
    """
    Build a dict mapping child -> { parent -> call_count }.
    """
    reverse_graph: Dict[str, Dict[str, int]] = {}
    for parent, child, call_count in edges:
        reverse_graph.setdefault(child, {})[parent] = reverse_graph.get(child, {}).get(parent, 0) + call_count
    return reverse_graph


def to_json_serializable_graph(edges: List[Tuple[str, str, int]]) -> Dict:
    """
    Convert edges into a JSON-serializable structure that includes nodes and links.
    Useful for dashboards or further processing.
    """
    nodes: Set[str] = set()
    links: List[Dict] = []
    for parent, child, call_count in edges:
        nodes.add(parent)
        nodes.add(child)
        links.append({"source": parent, "target": child, "callCount": call_count})
    return {"nodes": sorted(nodes), "links": links}


def fetch_and_build_service_map(jaeger_base_url: str, lookback: str = "1h") -> Dict:
    """
    Convenience function that fetches Jaeger dependencies and returns a JSON-ready graph.
    """
    deps = get_jaeger_network_map(jaeger_base_url, lookback)
    edges = build_service_graph_edges(deps)
    return to_json_serializable_graph(edges)


def _find_roots(edges: List[Tuple[str, str, int]]) -> Set[str]:
    children = {child for _, child, _ in edges}
    parents = {parent for parent, _, _ in edges}
    return parents - children


def _build_adjacency(edges: List[Tuple[str, str, int]]) -> Dict[str, List[Tuple[str, int]]]:
    adj: Dict[str, List[Tuple[str, int]]] = {}
    for parent, child, count in edges:
        adj.setdefault(parent, []).append((child, count))
    return adj


def compute_service_chains(edges: List[Tuple[str, str, int]], max_depth: int = 6) -> List[List[str]]:
    """
    Compute plausible request chains by DFS from root services.
    Caps depth to avoid cycles and overly long paths.
    """
    roots = _find_roots(edges)
    adj = _build_adjacency(edges)

    chains: List[List[str]] = []

    def dfs(node: str, path: List[str], depth: int, visited: Set[str]):
        if depth > max_depth:
            chains.append(path[:])
            return
        children = adj.get(node, [])
        if not children:
            chains.append(path[:])
            return
        for child, _ in sorted(children, key=lambda x: x[1], reverse=True):
            if child in visited:
                continue
            visited.add(child)
            path.append(child)
            dfs(child, path, depth + 1, visited)
            path.pop()
            visited.remove(child)

    # If no clear roots (all nodes are both parents and children), start from high-fan-in parents
    if not roots and edges:
        parent_counts: Dict[str, int] = {}
        for p, _, _ in edges:
            parent_counts[p] = parent_counts.get(p, 0) + 1
        roots = {p for p, _ in sorted(parent_counts.items(), key=lambda x: x[1], reverse=True)[:3]}

    for root in sorted(roots):
        dfs(root, [root], 1, {root})

    # Deduplicate identical chains
    dedup: Set[Tuple[str, ...]] = set()
    unique_chains: List[List[str]] = []
    for c in chains:
        t = tuple(c)
        if t not in dedup:
            dedup.add(t)
            unique_chains.append(c)
    return unique_chains


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Fetch Jaeger service dependency graph")
    parser.add_argument("jaeger", help="Base URL for Jaeger, e.g., http://127.0.0.1:16686")
    parser.add_argument("--lookback", default="3600000", help="Lookback in milliseconds (default: 3600000 = 1h)")
    args = parser.parse_args()

    graph = fetch_and_build_service_map(args.jaeger, args.lookback)
    # Save full graph JSON
    with open("service_graph.json", "w") as f:
        json.dump(graph, f, indent=2)

    # Pretty-print top service chains
    deps = get_jaeger_network_map(args.jaeger, args.lookback)
    edges = build_service_graph_edges(deps)
    chains = compute_service_chains(edges, max_depth=6)

    print("Found service chains (top paths):")
    for idx, chain in enumerate(chains[:10], start=1):
        print(f"  {idx}.  " + " -> ".join(chain))
    print("\nSaved full graph to service_graph.json")


