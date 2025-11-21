import json
from typing import Dict, List, Tuple, Set
from math import sqrt
from urllib3.util.retry import Retry
from requests.adapters import HTTPAdapter

# Default parameters when running this module as a script
DEFAULT_JAEGER_URL = "http://147.83.130.183:31686/"
DEFAULT_LAYOUT = "tree"  # choices: tree, spring, kamada_kawai, spectral, graphviz
DEFAULT_SEED = 42
DEFAULT_PNG_PATH = "service_graph.png"
DEFAULT_TREE_RANKSEP = 8  # vertical separation between ranks (graphviz)
DEFAULT_TREE_NODESEP = 12  # horizontal separation between nodes (graphviz)

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
    print(f"Fetching Jaeger dependencies from: {url}")

    # Robust requests session with retries for transient errors/timeouts
    session = requests.Session()
    retries = Retry(
        total=3,
        backoff_factor=0.5,
        status_forcelist=[429, 500, 502, 503, 504],
        allowed_methods=["GET"],
        raise_on_status=False,
    )
    adapter = HTTPAdapter(max_retries=retries)
    session.mount("http://", adapter)
    session.mount("https://", adapter)

    response = session.get(url, timeout=10)
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


def draw_service_graph(graph: Dict, output_path: str = "service_graph.png", layout: str = "spring", seed: int = 42) -> None:
    """
    Render a directed service graph using NetworkX with a readable, spaced-out layout.

    :param graph: Dict with keys 'nodes' (List[str]) and 'links' (List[{'source','target','callCount'}])
    :param output_path: Path to save the resulting image (e.g., PNG)
    :param layout: One of {'spring', 'kamada_kawai', 'spectral', 'graphviz'}
    :param seed: Random seed for reproducible layouts
    """
    try:
        import networkx as nx
        import matplotlib.pyplot as plt
    except Exception as exc:
        raise RuntimeError(
            "Rendering requires 'networkx' and 'matplotlib'. Install them via: pip install networkx matplotlib"
        ) from exc

    nodes = graph.get("nodes", [])
    links = graph.get("links", [])

    G = nx.DiGraph()
    G.add_nodes_from(nodes)
    for link in links:
        src = link.get("source")
        tgt = link.get("target")
        weight = int(link.get("callCount", 1) or 1)
        if src is None or tgt is None:
            continue
        G.add_edge(src, tgt, weight=weight)

    num_nodes = max(1, G.number_of_nodes())
    # Figure size scales with graph size, slightly larger for readability
    width = max(10.0, min(28.0, num_nodes * 0.7))
    height = max(8.0, min(22.0, num_nodes * 0.7))

    # Helper: compute levels (depths) from roots for coloring and tree layout
    def compute_depths(di_graph):
        from collections import deque, defaultdict
        indeg0 = [n for n in di_graph.nodes if di_graph.in_degree(n) == 0]
        if not indeg0:
            # fallback: pick highest out-degree as root(s)
            max_out = 0
            roots = []
            for n in di_graph.nodes:
                od = di_graph.out_degree(n)
                if od > max_out:
                    max_out = od
                    roots = [n]
                elif od == max_out:
                    roots.append(n)
        else:
            roots = indeg0
        depth = {n: None for n in di_graph.nodes}
        queue = deque()
        for r in roots:
            depth[r] = 0
            queue.append(r)
        while queue:
            u = queue.popleft()
            for v in di_graph.successors(u):
                if depth[v] is None or depth[v] > depth[u] + 1:
                    depth[v] = depth[u] + 1
                    queue.append(v)
        # Assign remaining (disconnected) nodes depth 0
        for n in di_graph.nodes:
            if depth[n] is None:
                depth[n] = 0
        return depth

    depths = compute_depths(G)

    # Compute positions
    if layout == "tree":
        try:
            from networkx.drawing.nx_pydot import graphviz_layout
            # Use DOT for hierarchical layout top->bottom, increase spacing
            import pydot
            graph = pydot.Dot(graph_type='digraph', rankdir='TB')
            graph.set_ranksep(str(DEFAULT_TREE_RANKSEP))
            graph.set_nodesep(str(DEFAULT_TREE_NODESEP))
            # networkx's graphviz_layout doesn't accept ranksep directly; we rely on global graph attrs
            pos = graphviz_layout(G, prog="dot")
        except Exception:
            # Fallback manual layering by depth if graphviz isn't available
            from collections import defaultdict
            layers = defaultdict(list)
            for n, d in depths.items():
                layers[d].append(n)
            pos = {}
            y_gap = 2.0
            x_gap = 2.2
            for depth_level, nodes_at_level in sorted(layers.items()):
                count = len(nodes_at_level)
                for i, n in enumerate(sorted(nodes_at_level)):
                    x = (i - (count - 1) / 2.0) * x_gap
                    y = -depth_level * y_gap
                    pos[n] = (x, y)
    elif layout == "kamada_kawai":
        pos = nx.kamada_kawai_layout(G, weight="weight")
    elif layout == "spectral":
        pos = nx.spectral_layout(G)
    elif layout == "graphviz":
        try:
            from networkx.drawing.nx_pydot import graphviz_layout
            # 'dot' is layered, 'neato' is force-directed. For readability, try 'neato'.
            pos = graphviz_layout(G, prog="neato")
        except Exception:
            # Fallback to spring if graphviz/pydot not available
            k = 1.2 / sqrt(num_nodes)
            pos = nx.spring_layout(G, k=k, iterations=300, seed=seed, weight="weight")
    else:  # spring / fruchterman-reingold
        k = 1.2 / sqrt(num_nodes)
        pos = nx.spring_layout(G, k=k, iterations=300, seed=seed, weight="weight")

    # Styling
    degrees = {n: (G.in_degree(n) + G.out_degree(n)) for n in G.nodes}
    # Node sizes scale by degree; slightly smaller to reduce clutter
    node_sizes = [max(450, 300 + 120 * degrees.get(n, 1)) for n in G.nodes]

    # Edge styling based on weight (callCount)
    edgelist = list(G.edges())
    edge_weights = [G[u][v].get("weight", 1) for u, v in edgelist]
    # Widths grow sublinearly to avoid very thick edges
    edge_widths = [max(0.8, 0.6 * sqrt(w)) for w in edge_weights]
    edge_alphas = [min(0.9, 0.3 + 0.05 * sqrt(w)) for w in edge_weights]

    # Draw
    fig, ax = plt.subplots(figsize=(width, height))
    ax.set_axis_off()

    # Color nodes by depth (stage of the tree)
    unique_depths = sorted(set(depths.values()))
    depth_to_color = {}
    palette = [
        "#4C78A8",  # blue
        "#F58518",  # orange
        "#54A24B",  # green
        "#E45756",  # red
        "#72B7B2",  # teal
        "#B279A2",  # purple
        "#FF9DA6",  # pink
        "#9D755D",  # brown
        "#BAB0AC",  # gray
    ]
    for idx, d in enumerate(unique_depths):
        depth_to_color[d] = palette[idx % len(palette)]
    node_colors = [depth_to_color[depths.get(n, 0)] for n in G.nodes]

    nodes_drawn = nx.draw_networkx_nodes(
        G,
        pos,
        node_size=node_sizes,
        node_color=node_colors,
        alpha=0.9,
        linewidths=1.2,
        edgecolors="#222222",
        ax=ax,
    )

    # Draw edges one pass for consistent alpha per edge
    nx.draw_networkx_edges(
        G,
        pos,
        edgelist=edgelist,
        width=edge_widths,
        alpha=edge_alphas,
        edge_color="#9ecae1",
        arrows=True,
        arrowsize=12,
        arrowstyle="-|>",
        connectionstyle="arc3,rad=0.05",
        ax=ax,
    )

    # Label sizing based on graph size
    label_font_size = max(6, 13 - int(num_nodes / 14))
    nx.draw_networkx_labels(
        G,
        pos,
        font_size=label_font_size,
        font_color="#111111",
        font_weight="regular",
        bbox=dict(boxstyle="round,pad=0.22", fc="white", ec="#DDDDDD", alpha=0.9),
        ax=ax,
    )

    # Edge labels (callCount) for smaller graphs only to reduce clutter
    if num_nodes <= 25:
        edge_labels = {(u, v): G[u][v].get("weight", 1) for u, v in edgelist}
        nx.draw_networkx_edge_labels(
            G,
            pos,
            edge_labels=edge_labels,
            font_size=max(6, label_font_size - 2),
            label_pos=0.5,
            rotate=False,
            bbox=dict(boxstyle="round,pad=0.1", fc="white", ec="none", alpha=0.5),
            ax=ax,
        )

    plt.tight_layout()
    plt.savefig(output_path, dpi=200, bbox_inches="tight")
    plt.close(fig)


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

    parser = argparse.ArgumentParser(description="Fetch/Render Jaeger service dependency graph")
    parser.add_argument(
        "jaeger",
        nargs="?",
        default=DEFAULT_JAEGER_URL,
        help=f"Base URL for Jaeger (default: {DEFAULT_JAEGER_URL})",
    )
    parser.add_argument(
        "--lookback",
        default="3600000",
        help="Lookback in milliseconds (default: 3600000 = 1h)",
    )
    parser.add_argument(
        "--from-json",
        dest="from_json",
        help="Path to existing graph JSON (with keys 'nodes' and 'links') to render",
    )
    parser.add_argument(
        "--png",
        dest="png",
        help="If set, render graph to this PNG path (requires networkx & matplotlib)",
    )
    parser.add_argument(
        "--layout",
        choices=["tree", "spring", "kamada_kawai", "spectral", "graphviz"],
        default=DEFAULT_LAYOUT,
        help=f"Layout algorithm for rendering (default: {DEFAULT_LAYOUT})",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=DEFAULT_SEED,
        help=f"Random seed for layout reproducibility (default: {DEFAULT_SEED})",
    )
    args = parser.parse_args()

    if args.from_json:
        with open(args.from_json, "r") as f:
            graph = json.load(f)
        deps = []
        edges = []
    else:
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

    # If no explicit PNG path was provided, default to DEFAULT_PNG_PATH
    png_path = args.png or DEFAULT_PNG_PATH
    draw_service_graph(graph, output_path=png_path, layout=args.layout, seed=args.seed)
    print(f"Rendered graph to {png_path}")


