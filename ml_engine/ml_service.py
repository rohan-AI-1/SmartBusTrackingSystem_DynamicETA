# ml_engine/ml_service.py
import os
import json
import math
from datetime import datetime
from zoneinfo import ZoneInfo
import numpy as np
from fastapi import FastAPI
from pydantic import BaseModel

IST = ZoneInfo("Asia/Kolkata")
app = FastAPI(title="Vijayapura Smart Transit AI/ML Engine", version="1.0.0")

MODEL_DIR = os.path.join(os.path.dirname(__file__), "models")
JOBLIB_ETA_PATH = os.path.join(MODEL_DIR, "eta_rf_model.joblib")
JOBLIB_ISO_PATH = os.path.join(MODEL_DIR, "telemetry_iforest.joblib")
NUMPY_BUNDLE_PATH = os.path.join(MODEL_DIR, "numpy_ml_bundle.json")
SPEED_MATRIX_PATH = os.path.join(MODEL_DIR, "corridor_speed_matrix.json")
DWELL_MATRIX_PATH = os.path.join(MODEL_DIR, "stop_dwell_matrix.json")


def load_json_file(path: str, default):
    if os.path.exists(path):
        try:
            with open(path, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            pass
    return default


def save_json_file(path: str, payload) -> None:
    try:
        os.makedirs(MODEL_DIR, exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(payload, f, indent=2)
    except Exception:
        pass


def get_traffic_regime(hour: int, dow: int | None = None) -> tuple[bool, str]:
    is_weekday = True if dow is None else (dow < 6)
    is_peak = (8 <= hour <= 10 and is_weekday) or (17 <= hour <= 20)
    return is_peak, ("PEAK" if is_peak else "OFFPEAK")


# Auto-train initial models if models/ folder is missing on cloud cold deploy
if not (os.path.exists(JOBLIB_ETA_PATH) and os.path.exists(JOBLIB_ISO_PATH)) and not os.path.exists(NUMPY_BUNDLE_PATH):
    from train_models import train_and_save
    train_and_save()

SPEED_MATRIX: dict[str, dict] = load_json_file(SPEED_MATRIX_PATH, {})
DWELL_MATRIX: dict[str, dict] = load_json_file(DWELL_MATRIX_PATH, {})

USE_SKLEARN = False
ETA_BUNDLE = None
IFOREST_MODEL = None
NUMPY_BUNDLE = None

if os.path.exists(JOBLIB_ETA_PATH) and os.path.exists(JOBLIB_ISO_PATH):
    try:
        import joblib
        ETA_BUNDLE = joblib.load(JOBLIB_ETA_PATH)
        IFOREST_MODEL = joblib.load(JOBLIB_ISO_PATH)
        USE_SKLEARN = True
    except Exception:
        USE_SKLEARN = False

if not USE_SKLEARN:
    NUMPY_BUNDLE = load_json_file(NUMPY_BUNDLE_PATH, None)


class EtaRequest(BaseModel):
    remaining_meters: float
    remaining_stops: int
    current_speed_kmh: float
    hour_of_day: int | None = None
    day_of_week: int | None = None


class AnomalyRequest(BaseModel):
    call_sign: str
    speed_kmh: float
    off_route_meters: float
    stationary_seconds: float
    speed_variance: float = 2.0


class SegmentObservation(BaseModel):
    corridor_id: str
    direction: str
    from_stop: str
    to_stop: str
    distance_meters: float
    elapsed_seconds: float
    hour_of_day: int | None = None


class DwellObservation(BaseModel):
    stop_name: str
    crowd_level: str = "SEATS"
    dwell_seconds: float
    hour_of_day: int | None = None


class HeadwayCheckRequest(BaseModel):
    corridor_id: str
    direction: str
    lead_call_sign: str
    trail_call_sign: str
    stop_gap: float
    distance_meters: float
    trail_speed_kmh: float
    target_headway_min: float = 6.0


@app.get("/health")
def health():
    if USE_SKLEARN:
        return {
            "status": "ONLINE",
            "eta_model": "RandomForestRegressor (scikit-learn)",
            "eta_r2": round(float(ETA_BUNDLE["r2"]), 4),
            "eta_mae_minutes": round(float(ETA_BUNDLE["mae"]), 2),
            "anomaly_model": "IsolationForest (scikit-learn)",
        }
    return {
        "status": "ONLINE",
        "eta_model": "RidgeRegressor (NumPy)",
        "eta_r2": NUMPY_BUNDLE["r2"] if NUMPY_BUNDLE else 0.0,
        "eta_mae_minutes": NUMPY_BUNDLE["mae"] if NUMPY_BUNDLE else 0.0,
        "anomaly_model": "Z-Score Kinematic Anomaly Detector (NumPy)",
    }


@app.post("/train/segment")
def train_segment(obs: SegmentObservation):
    if obs.elapsed_seconds <= 5 or obs.distance_meters <= 30:
        return {"updated": False, "reason": "Segment too short"}

    observed_kmh = min(65.0, max(3.0, (obs.distance_meters / 1000.0) / (obs.elapsed_seconds / 3600.0)))
    now_ist = datetime.now(IST)
    hour = obs.hour_of_day if obs.hour_of_day is not None else now_ist.hour
    _, bucket = get_traffic_regime(hour)
    key = f"{obs.corridor_id}:{obs.direction}:{bucket}"

    prev = SPEED_MATRIX.get(key)
    alpha = 0.25
    if prev:
        new_ema = round((1 - alpha) * prev["ema_kmh"] + alpha * observed_kmh, 2)
        samples = prev["samples"] + 1
    else:
        new_ema = round(observed_kmh, 2)
        samples = 1

    SPEED_MATRIX[key] = {
        "ema_kmh": new_ema,
        "samples": samples,
        "last_segment": f"{obs.from_stop} -> {obs.to_stop}",
        "updated_at": now_ist.isoformat(),
    }
    save_json_file(SPEED_MATRIX_PATH, SPEED_MATRIX)

    return {"updated": True, "key": key, "ema_kmh": new_ema, "samples": samples}


@app.post("/train/dwell")
def train_dwell(obs: DwellObservation):
    if obs.dwell_seconds < 8 or obs.dwell_seconds > 600:
        return {"updated": False, "is_surge": False}

    now_ist = datetime.now(IST)
    hour = obs.hour_of_day if obs.hour_of_day is not None else now_ist.hour
    _, bucket = get_traffic_regime(hour)
    clean_stop = obs.stop_name.strip().lower()
    key = f"{clean_stop}:{bucket}"

    prev = DWELL_MATRIX.get(key)
    alpha = 0.3
    if prev:
        new_dwell = round((1 - alpha) * prev["ema_dwell_sec"] + alpha * obs.dwell_seconds, 1)
        samples = prev["samples"] + 1
    else:
        new_dwell = round(obs.dwell_seconds, 1)
        samples = 1

    DWELL_MATRIX[key] = {
        "stop_name": obs.stop_name.strip(),
        "ema_dwell_sec": new_dwell,
        "samples": samples,
        "last_crowd": obs.crowd_level,
        "updated_at": now_ist.isoformat(),
    }
    save_json_file(DWELL_MATRIX_PATH, DWELL_MATRIX)

    is_surge = obs.dwell_seconds >= 75.0 or new_dwell >= 70.0 or obs.crowd_level == "FULL"
    return {
        "updated": True,
        "stop_name": obs.stop_name.strip(),
        "ema_dwell_sec": new_dwell,
        "is_surge": is_surge,
        "extra_delay_min": max(1, int(round(new_dwell / 60.0))),
    }


@app.post("/predict/headway")
def predict_headway(req: HeadwayCheckRequest):
    effective_speed = max(12.0, req.trail_speed_kmh)
    estimated_gap_min = round(((req.distance_meters / 1000.0) / effective_speed) * 60.0 + (req.stop_gap * 0.4), 1)
    is_bunching = estimated_gap_min < (req.target_headway_min * 0.55) or req.stop_gap < 1.2

    hold_seconds = 0
    if is_bunching:
        deficit_min = max(0.5, (req.target_headway_min * 0.65) - estimated_gap_min)
        hold_seconds = int(min(90, max(30, round(deficit_min * 25))))

    return {
        "is_bunching": is_bunching,
        "estimated_headway_min": estimated_gap_min,
        "recommended_hold_seconds": hold_seconds,
        "advice": (
            f"Bunching alert: {estimated_gap_min} min behind {req.lead_call_sign}. Hold {hold_seconds}s at next stop to equalize headway."
            if is_bunching
            else f"Healthy headway ({estimated_gap_min} min behind {req.lead_call_sign})."
        ),
    }


@app.post("/predict/eta")
def predict_eta(req: EtaRequest):
    now_ist = datetime.now(IST)
    hour = req.hour_of_day if req.hour_of_day is not None else now_ist.hour
    dow = req.day_of_week if req.day_of_week is not None else now_ist.weekday()

    is_peak_bool, bucket = get_traffic_regime(hour, dow)
    is_peak = 1.0 if is_peak_bool else 0.0
    hour_sin = math.sin(2 * math.pi * hour / 24.0)
    hour_cos = math.cos(2 * math.pi * hour / 24.0)

    features = np.array([[
        max(0.0, req.remaining_meters),
        float(max(0, req.remaining_stops)),
        max(0.0, req.current_speed_kmh),
        hour_sin,
        hour_cos,
        is_peak,
    ]])

    if USE_SKLEARN:
        pred_min = float(ETA_BUNDLE["model"].predict(features)[0])
        model_name = "RandomForestRegressor"
    else:
        weights = np.array(NUMPY_BUNDLE["weights"])
        feat_b = np.column_stack([np.ones(1), features])
        pred_min = float((feat_b @ weights)[0])
        model_name = "RidgeRegressor"

    matching_keys = [k for k in SPEED_MATRIX if k.endswith(f":{bucket}")]
    if matching_keys and req.remaining_meters > 60:
        avg_learned_kmh = sum(SPEED_MATRIX[k]["ema_kmh"] for k in matching_keys) / len(matching_keys)
        learned_min = ((req.remaining_meters / 1000.0) / max(5.0, avg_learned_kmh)) * 60.0 + (req.remaining_stops * 0.4)
        pred_min = 0.6 * pred_min + 0.4 * learned_min

    dwell_keys = [k for k in DWELL_MATRIX if k.endswith(f":{bucket}")]
    if dwell_keys and req.remaining_stops > 0:
        avg_dwell_sec = sum(DWELL_MATRIX[k]["ema_dwell_sec"] for k in dwell_keys) / len(dwell_keys)
        extra_dwell_sec = max(0.0, avg_dwell_sec - 20.0) * req.remaining_stops
        pred_min += extra_dwell_sec / 60.0

    eta_rounded = max(1, int(round(pred_min))) if req.remaining_meters > 60 else 0

    return {
        "eta_minutes": eta_rounded,
        "raw_prediction": round(pred_min, 2),
        "traffic_regime": "PEAK_CONGESTION" if is_peak_bool else "NORMAL_FLOW",
        "model": f"{model_name}+OnlineMatrix" if matching_keys else model_name,
    }


@app.post("/detect/anomaly")
def detect_anomaly(req: AnomalyRequest):
    vec = np.array([[
        req.speed_kmh,
        req.off_route_meters,
        req.stationary_seconds,
        req.speed_variance,
    ]])

    if USE_SKLEARN:
        pred = int(IFOREST_MODEL.predict(vec)[0])
        score = float(IFOREST_MODEL.decision_function(vec)[0])
        is_anomaly = pred == -1
    else:
        means = np.array(NUMPY_BUNDLE["normal_means"])
        stds = np.array(NUMPY_BUNDLE["normal_stds"])
        z_scores = np.abs((vec[0] - means) / stds)
        max_z = float(np.max(z_scores))
        is_anomaly = max_z > 3.2
        score = round(1.0 - (max_z / 4.0), 4)

    anomaly_type = "NORMAL"
    if is_anomaly:
        if req.off_route_meters > 85:
            anomaly_type = "ROUTE_DEVIATION"
        elif req.stationary_seconds > 120 and req.speed_kmh < 2.0:
            anomaly_type = "UNEXPECTED_STALL_OR_JAM"
        else:
            anomaly_type = "KINEMATIC_ANOMALY"

    return {
        "call_sign": req.call_sign,
        "is_anomaly": is_anomaly,
        "anomaly_type": anomaly_type,
        "anomaly_score": round(score, 4),
    }