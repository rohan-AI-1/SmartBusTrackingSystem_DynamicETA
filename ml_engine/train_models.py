# ml_engine/train_models.py
import os
import json
import numpy as np

MODEL_DIR = os.path.join(os.path.dirname(__file__), "models")
os.makedirs(MODEL_DIR, exist_ok=True)


def generate_vijayapura_corridor_dataset(n_samples: int = 3500):
    rng = np.random.default_rng(42)

    remaining_meters = rng.uniform(120, 6500, n_samples)
    remaining_stops = np.clip(np.round(remaining_meters / 650.0) + rng.integers(0, 2, n_samples), 1, 12)
    current_speed_kmh = rng.uniform(0.0, 48.0, n_samples)
    hour_of_day = rng.integers(6, 22, n_samples)
    day_of_week = rng.integers(0, 7, n_samples)

    is_morning_rush = ((hour_of_day >= 8) & (hour_of_day <= 10) & (day_of_week < 6)).astype(float)
    is_evening_rush = ((hour_of_day >= 17) & (hour_of_day <= 20)).astype(float)
    is_peak = np.maximum(is_morning_rush, is_evening_rush)

    base_corridor_speed = np.where(
        is_peak == 1,
        rng.uniform(14.0, 22.0, n_samples),
        rng.uniform(22.0, 32.0, n_samples),
    )
    blended_speed = 0.65 * base_corridor_speed + 0.35 * np.maximum(current_speed_kmh, 8.0)

    drive_minutes = (remaining_meters / 1000.0) / blended_speed * 60.0
    dwell_minutes = remaining_stops * np.where(is_peak == 1, 0.65, 0.35)
    noise = rng.normal(0.0, 0.45, n_samples)

    eta_minutes = np.clip(drive_minutes + dwell_minutes + noise, 0.5, 90.0)

    hour_sin = np.sin(2 * np.pi * hour_of_day / 24.0)
    hour_cos = np.cos(2 * np.pi * hour_of_day / 24.0)

    X = np.column_stack([
        remaining_meters,
        remaining_stops,
        current_speed_kmh,
        hour_sin,
        hour_cos,
        is_peak,
    ])
    return X, eta_minutes


def train_and_save():
    X, y = generate_vijayapura_corridor_dataset()
    split = int(0.8 * len(X))
    X_train, X_test = X[:split], X[split:]
    y_train, y_test = y[:split], y[split:]

    try:
        import joblib
        from sklearn.ensemble import RandomForestRegressor, IsolationForest
        from sklearn.metrics import mean_absolute_error, r2_score

        rf = RandomForestRegressor(
            n_estimators=120,
            max_depth=12,
            min_samples_leaf=3,
            random_state=42,
        )
        rf.fit(X_train, y_train)
        preds = rf.predict(X_test)
        mae = float(mean_absolute_error(y_test, preds))
        r2 = float(r2_score(y_test, preds))

        joblib.dump(
            {"backend": "sklearn", "model": rf, "mae": mae, "r2": r2},
            os.path.join(MODEL_DIR, "eta_rf_model.joblib"),
        )
        print(f"[ETA MODEL TRAINED] RandomForestRegressor | R2={r2:.4f} | MAE={mae:.2f} min")

        rng = np.random.default_rng(99)
        normal_data = np.column_stack([
            rng.uniform(8.0, 45.0, 2500),
            rng.uniform(0.0, 22.0, 2500),
            rng.uniform(0.0, 45.0, 2500),
            rng.uniform(0.5, 8.0, 2500),
        ])
        iso = IsolationForest(n_estimators=100, contamination=0.04, random_state=42)
        iso.fit(normal_data)
        joblib.dump(iso, os.path.join(MODEL_DIR, "telemetry_iforest.joblib"))
        print("[ANOMALY MODEL TRAINED] IsolationForest saved successfully.")

    except Exception as dll_err:
        print(f"[INFO] Falling back to pure-NumPy ML engine: {dll_err}")
        X_b = np.column_stack([np.ones(len(X_train)), X_train])
        reg = 1e-3 * np.eye(X_b.shape[1])
        reg[0, 0] = 0.0
        weights = np.linalg.solve(X_b.T @ X_b + reg, X_b.T @ y_train)

        X_test_b = np.column_stack([np.ones(len(X_test)), X_test])
        preds = X_test_b @ weights
        mae = float(np.mean(np.abs(y_test - preds)))
        ss_res = float(np.sum((y_test - preds) ** 2))
        ss_tot = float(np.sum((y_test - np.mean(y_test)) ** 2))
        r2 = 1.0 - (ss_res / ss_tot)

        meta = {
            "backend": "numpy_ridge",
            "weights": weights.tolist(),
            "mae": round(mae, 3),
            "r2": round(r2, 4),
            "normal_means": [24.0, 8.0, 15.0, 3.5],
            "normal_stds": [10.0, 8.0, 20.0, 2.5],
        }
        with open(os.path.join(MODEL_DIR, "numpy_ml_bundle.json"), "w", encoding="utf-8") as f:
            json.dump(meta, f, indent=2)
        print(f"[NUMPY ML TRAINED] R2={r2:.4f} | MAE={mae:.2f} min -> Saved to models/numpy_ml_bundle.json")


if __name__ == "__main__":
    train_and_save()