"""Lambda de Amazon Lex V2 (respuestas dinamicas sobre la Facultad de Ingenieria).

IMPORTANTE: los textos de FAQ son de ejemplo. EDITALOS con los datos reales
(horarios, telefonos, correos, requisitos) antes de la calificacion.
"""
from datetime import datetime, timedelta, timezone

GT = timezone(timedelta(hours=-6))  # Guatemala (UTC-6, sin horario de verano)

# --- EDITAR con datos reales ---
HORA_APERTURA = 8
HORA_CIERRE = 16

FAQ = {
    "Saludo": "¡Hola! Soy el asistente de la Facultad de Ingeniería. Pregúntame por horarios, ubicación, carreras, inscripción o contacto.",
    "Ubicacion": "La Facultad de Ingeniería está en la Ciudad Universitaria, zona 12, Ciudad de Guatemala (USAC).",
    "Carreras": "La Facultad de Ingeniería ofrece estas carreras: 01 - Civil, 02 - Química, 03 - Mecánica, 04 - Eléctrica, 05 - Industrial, 06 - Mecánica Eléctrica, 07 - Mecánica Industrial, 09 - Ciencias y Sistemas, 13 - Electrónica y 35 - Ambiental.",
    "Inscripcion": "Para inscribirte debes cumplir el proceso de inscripción y asignación de cursos de la facultad en las fechas del calendario oficial. Consulta los requisitos vigentes en Control Académico.",
    "Contacto": "Puedes comunicarte con la facultad por sus canales oficiales: teléfono 24189100 o el correo de Control Académico, controlacademico@ing.usac.edu.gt.",
}


def horario():
    ahora = datetime.now(GT)
    abierto = ahora.weekday() < 5 and HORA_APERTURA <= ahora.hour < HORA_CIERRE
    estado = "Ahora mismo estamos ABIERTOS." if abierto else "Ahora mismo estamos CERRADOS."
    return (
        f"El horario de atención es de lunes a viernes de {HORA_APERTURA}:00 a {HORA_CIERRE}:00. "
        f"{estado} (Hora de Guatemala: {ahora.strftime('%H:%M')})"
    )


def lambda_handler(event, context):
    intent = event["sessionState"]["intent"]
    name = intent["name"]
    text = horario() if name == "Horarios" else FAQ.get(
        name, "No tengo información sobre eso todavía. Intenta con horarios, ubicación, carreras, inscripción o contacto."
    )
    intent["state"] = "Fulfilled"
    return {
        "sessionState": {"dialogAction": {"type": "Close"}, "intent": intent},
        "messages": [{"contentType": "PlainText", "content": text}],
    }
