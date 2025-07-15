-- =====================================================
-- CONFIGURAÇÕES DE SEGURANÇA AVANÇADAS - CIDADÃO ATIVO
-- =====================================================

-- =====================================================
-- 1. POLÍTICAS RLS DETALHADAS
-- =====================================================

-- Limpar políticas existentes para recriar
DROP POLICY IF EXISTS "Usuários podem ver próprio perfil" ON usuarios;
DROP POLICY IF EXISTS "Usuários podem atualizar próprio perfil" ON usuarios;
DROP POLICY IF EXISTS "Usuários podem ver próprias ocorrências" ON ocorrencias;
DROP POLICY IF EXISTS "Usuários podem criar ocorrências" ON ocorrencias;
DROP POLICY IF EXISTS "Admins podem ver ocorrências da prefeitura" ON ocorrencias;
DROP POLICY IF EXISTS "Admins podem atualizar ocorrências da prefeitura" ON ocorrencias;

-- Políticas para tabela usuarios
CREATE POLICY "usuarios_select_own" ON usuarios
    FOR SELECT USING (auth.uid() = id);

CREATE POLICY "usuarios_update_own" ON usuarios
    FOR UPDATE USING (auth.uid() = id);

CREATE POLICY "usuarios_insert_own" ON usuarios
    FOR INSERT WITH CHECK (auth.uid() = id);

-- Políticas para tabela ocorrencias
CREATE POLICY "ocorrencias_select_owner" ON ocorrencias
    FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "ocorrencias_select_admin" ON ocorrencias
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM admin_prefeituras ap
            WHERE ap.user_id = auth.uid() 
            AND ap.prefeitura_id = ocorrencias.prefeitura_id
            AND ap.is_active = true
        )
    );

CREATE POLICY "ocorrencias_insert_authenticated" ON ocorrencias
    FOR INSERT WITH CHECK (
        auth.uid() = user_id 
        AND auth.uid() IS NOT NULL
    );

CREATE POLICY "ocorrencias_update_admin" ON ocorrencias
    FOR UPDATE USING (
        EXISTS (
            SELECT 1 FROM admin_prefeituras ap
            WHERE ap.user_id = auth.uid() 
            AND ap.prefeitura_id = ocorrencias.prefeitura_id
            AND ap.is_active = true
        )
    );

-- Políticas para comentários
CREATE POLICY "comentarios_select_related" ON comentarios
    FOR SELECT USING (
        -- Usuário dono da ocorrência pode ver todos os comentários não internos
        EXISTS (
            SELECT 1 FROM ocorrencias o 
            WHERE o.id = comentarios.ocorrencia_id 
            AND o.user_id = auth.uid()
            AND (comentarios.is_internal = false OR comentarios.user_id = auth.uid())
        )
        OR
        -- Admin pode ver todos os comentários
        EXISTS (
            SELECT 1 FROM ocorrencias o
            JOIN admin_prefeituras ap ON ap.prefeitura_id = o.prefeitura_id
            WHERE o.id = comentarios.ocorrencia_id 
            AND ap.user_id = auth.uid()
            AND ap.is_active = true
        )
    );

CREATE POLICY "comentarios_insert_related" ON comentarios
    FOR INSERT WITH CHECK (
        -- Usuário dono da ocorrência pode comentar (não interno)
        (
            EXISTS (
                SELECT 1 FROM ocorrencias o 
                WHERE o.id = comentarios.ocorrencia_id 
                AND o.user_id = auth.uid()
            )
            AND comentarios.is_internal = false
            AND comentarios.user_id = auth.uid()
        )
        OR
        -- Admin pode comentar (interno ou não)
        (
            EXISTS (
                SELECT 1 FROM ocorrencias o
                JOIN admin_prefeituras ap ON ap.prefeitura_id = o.prefeitura_id
                WHERE o.id = comentarios.ocorrencia_id 
                AND ap.user_id = auth.uid()
                AND ap.is_active = true
            )
            AND comentarios.user_id = auth.uid()
        )
    );

-- Políticas para status_logs (somente leitura para usuários)
CREATE POLICY "status_logs_select_related" ON status_logs
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM ocorrencias o 
            WHERE o.id = status_logs.ocorrencia_id 
            AND (
                o.user_id = auth.uid() 
                OR 
                EXISTS (
                    SELECT 1 FROM admin_prefeituras ap 
                    WHERE ap.prefeitura_id = o.prefeitura_id 
                    AND ap.user_id = auth.uid()
                    AND ap.is_active = true
                )
            )
        )
    );

-- Políticas para categorias (leitura pública)
CREATE POLICY "categorias_select_all" ON categorias
    FOR SELECT USING (is_active = true);

-- Políticas para prefeituras (leitura pública)
CREATE POLICY "prefeituras_select_all" ON prefeituras
    FOR SELECT USING (is_active = true);

-- Políticas para admin_prefeituras (apenas próprios registros)
CREATE POLICY "admin_prefeituras_select_own" ON admin_prefeituras
    FOR SELECT USING (user_id = auth.uid());

-- =====================================================
-- 2. FUNÇÕES DE SEGURANÇA AUXILIARES
-- =====================================================

-- Função para verificar se usuário é admin de uma prefeitura
CREATE OR REPLACE FUNCTION is_prefeitura_admin(prefeitura_uuid UUID)
RETURNS BOOLEAN AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM admin_prefeituras
        WHERE user_id = auth.uid()
        AND prefeitura_id = prefeitura_uuid
        AND is_active = true
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Função para verificar se usuário é dono de uma ocorrência
CREATE OR REPLACE FUNCTION is_occurrence_owner(occurrence_uuid UUID)
RETURNS BOOLEAN AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM ocorrencias
        WHERE id = occurrence_uuid
        AND user_id = auth.uid()
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Função para obter prefeitura do usuário admin
CREATE OR REPLACE FUNCTION get_user_prefeitura()
RETURNS UUID AS $$
DECLARE
    prefeitura_uuid UUID;
BEGIN
    SELECT prefeitura_id INTO prefeitura_uuid
    FROM admin_prefeituras
    WHERE user_id = auth.uid()
    AND is_active = true
    LIMIT 1;
    
    RETURN prefeitura_uuid;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- =====================================================
-- 3. TRIGGERS DE VALIDAÇÃO E SEGURANÇA
-- =====================================================

-- Trigger para validar dados da ocorrência antes da inserção
CREATE OR REPLACE FUNCTION validate_occurrence_data()
RETURNS TRIGGER AS $$
BEGIN
    -- Validar coordenadas (exemplo: Brasil)
    IF NEW.latitude < -35 OR NEW.latitude > 5 OR 
       NEW.longitude < -75 OR NEW.longitude > -30 THEN
        RAISE EXCEPTION 'Coordenadas fora do território brasileiro';
    END IF;
    
    -- Validar categoria existe e está ativa
    IF NOT EXISTS (
        SELECT 1 FROM categorias 
        WHERE id = NEW.categoria_id AND is_active = true
    ) THEN
        RAISE EXCEPTION 'Categoria inválida ou inativa';
    END IF;
    
    -- Validar prefeitura existe e está ativa
    IF NOT EXISTS (
        SELECT 1 FROM prefeituras 
        WHERE id = NEW.prefeitura_id AND is_active = true
    ) THEN
        RAISE EXCEPTION 'Prefeitura inválida ou inativa';
    END IF;
    
    -- Limitar número de fotos e vídeos
    IF array_length(NEW.fotos, 1) > 5 THEN
        RAISE EXCEPTION 'Máximo 5 fotos permitidas';
    END IF;
    
    IF array_length(NEW.videos, 1) > 2 THEN
        RAISE EXCEPTION 'Máximo 2 vídeos permitidos';
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_validate_occurrence
    BEFORE INSERT OR UPDATE ON ocorrencias
    FOR EACH ROW
    EXECUTE FUNCTION validate_occurrence_data();

-- Trigger para prevenir alteração de dados críticos
CREATE OR REPLACE FUNCTION prevent_critical_changes()
RETURNS TRIGGER AS $$
BEGIN
    -- Prevenir alteração do protocolo
    IF OLD.protocolo IS DISTINCT FROM NEW.protocolo THEN
        RAISE EXCEPTION 'Protocolo não pode ser alterado';
    END IF;
    
    -- Prevenir alteração do user_id
    IF OLD.user_id IS DISTINCT FROM NEW.user_id THEN
        RAISE EXCEPTION 'Usuário da ocorrência não pode ser alterado';
    END IF;
    
    -- Prevenir alteração da data de criação
    IF OLD.created_at IS DISTINCT FROM NEW.created_at THEN
        RAISE EXCEPTION 'Data de criação não pode ser alterada';
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_prevent_critical_changes
    BEFORE UPDATE ON ocorrencias
    FOR EACH ROW
    EXECUTE FUNCTION prevent_critical_changes();

-- =====================================================
-- 4. RATE LIMITING E THROTTLING
-- =====================================================

-- Tabela para controle de rate limiting
CREATE TABLE IF NOT EXISTS rate_limits (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES usuarios(id),
    action_type VARCHAR(50) NOT NULL, -- 'create_occurrence', 'upload_media', etc.
    ip_address INET,
    requests_count INTEGER DEFAULT 1,
    window_start TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Índices para rate limiting
CREATE INDEX idx_rate_limits_user_action ON rate_limits(user_id, action_type, window_start);
CREATE INDEX idx_rate_limits_ip_action ON rate_limits(ip_address, action_type, window_start);

-- Função para verificar rate limit
CREATE OR REPLACE FUNCTION check_rate_limit(
    p_user_id UUID,
    p_ip_address INET,
    p_action_type VARCHAR(50),
    p_max_requests INTEGER DEFAULT 10,
    p_window_minutes INTEGER DEFAULT 60
)
RETURNS BOOLEAN AS $$
DECLARE
    current_count INTEGER;
    window_start TIMESTAMP WITH TIME ZONE;
BEGIN
    window_start := NOW() - INTERVAL '1 minute' * p_window_minutes;
    
    -- Contar requests do usuário na janela de tempo
    SELECT COALESCE(SUM(requests_count), 0) INTO current_count
    FROM rate_limits
    WHERE user_id = p_user_id
    AND action_type = p_action_type
    AND window_start >= window_start;
    
    -- Se ultrapassou o limite, retorna false
    IF current_count >= p_max_requests THEN
        RETURN FALSE;
    END IF;
    
    -- Registra a tentativa
    INSERT INTO rate_limits (user_id, action_type, ip_address)
    VALUES (p_user_id, p_action_type, p_ip_address);
    
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- =====================================================
-- 5. LOGS DE AUDITORIA
-- =====================================================

-- Tabela de logs de auditoria
CREATE TABLE IF NOT EXISTS audit_logs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    table_name VARCHAR(50) NOT NULL,
    operation VARCHAR(10) NOT NULL, -- INSERT, UPDATE, DELETE
    record_id UUID,
    user_id UUID REFERENCES usuarios(id),
    old_values JSONB,
    new_values JSONB,
    ip_address INET,
    user_agent TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Índices para audit logs
CREATE INDEX idx_audit_logs_table_operation ON audit_logs(table_name, operation, created_at);
CREATE INDEX idx_audit_logs_user ON audit_logs(user_id, created_at);
CREATE INDEX idx_audit_logs_record ON audit_logs(table_name, record_id);

-- Função genérica de auditoria
CREATE OR REPLACE FUNCTION audit_trigger_function()
RETURNS TRIGGER AS $$
DECLARE
    old_values JSONB := NULL;
    new_values JSONB := NULL;
BEGIN
    IF TG_OP = 'DELETE' THEN
        old_values := to_jsonb(OLD);
    ELSIF TG_OP = 'UPDATE' THEN
        old_values := to_jsonb(OLD);
        new_values := to_jsonb(NEW);
    ELSIF TG_OP = 'INSERT' THEN
        new_values := to_jsonb(NEW);
    END IF;
    
    INSERT INTO audit_logs (
        table_name,
        operation,
        record_id,
        user_id,
        old_values,
        new_values
    ) VALUES (
        TG_TABLE_NAME,
        TG_OP,
        CASE 
            WHEN TG_OP = 'DELETE' THEN OLD.id
            ELSE NEW.id
        END,
        auth.uid(),
        old_values,
        new_values
    );
    
    RETURN CASE TG_OP
        WHEN 'DELETE' THEN OLD
        ELSE NEW
    END;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Aplicar auditoria nas tabelas principais
CREATE TRIGGER audit_ocorrencias
    AFTER INSERT OR UPDATE OR DELETE ON ocorrencias
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_function();

CREATE TRIGGER audit_status_logs
    AFTER INSERT OR UPDATE OR DELETE ON status_logs
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_function();

-- =====================================================
-- 6. LIMPEZA AUTOMÁTICA DE DADOS
-- =====================================================

-- Função para limpeza de dados antigos
CREATE OR REPLACE FUNCTION cleanup_old_data()
RETURNS void AS $$
BEGIN
    -- Limpar rate limits antigos (mais de 24h)
    DELETE FROM rate_limits 
    WHERE created_at < NOW() - INTERVAL '24 hours';
    
    -- Limpar logs de auditoria antigos (mais de 1 ano)
    DELETE FROM audit_logs 
    WHERE created_at < NOW() - INTERVAL '1 year';
    
    -- Log da limpeza
    RAISE NOTICE 'Cleanup completed at %', NOW();
END;
$$ LANGUAGE plpgsql;

-- =====================================================
-- 7. CONFIGURAÇÕES DE BACKUP E RECOVERY
-- =====================================================

-- View para backup essencial (sem dados sensíveis)
CREATE VIEW backup_essential AS
SELECT 
    'usuarios' as table_name,
    jsonb_build_object(
        'id', id,
        'nome', nome,
        'cidade', cidade,
        'estado', estado,
        'created_at', created_at
    ) as data
FROM usuarios
WHERE is_active = true

UNION ALL

SELECT 
    'ocorrencias' as table_name,
    jsonb_build_object(
        'id', id,
        'protocolo', protocolo,
        'titulo', titulo,
        'status', status,
        'categoria_id', categoria_id,
        'prefeitura_id', prefeitura_id,
        'created_at', created_at,
        'resolved_at', resolved_at
    ) as data
FROM ocorrencias;

-- =====================================================
-- 8. CONFIGURAÇÕES DE MONITORING
-- =====================================================

-- View para monitoramento de performance
CREATE VIEW monitoring_stats AS
SELECT 
    'total_usuarios' as metric,
    COUNT(*)::text as value,
    NOW() as timestamp
FROM usuarios WHERE is_active = true

UNION ALL

SELECT 
    'total_ocorrencias' as metric,
    COUNT(*)::text as value,
    NOW() as timestamp
FROM ocorrencias

UNION ALL

SELECT 
    'ocorrencias_pendentes' as metric,
    COUNT(*)::text as value,
    NOW() as timestamp
FROM ocorrencias 
WHERE status IN ('recebido', 'em_analise', 'em_atendimento')

UNION ALL

SELECT 
    'tempo_medio_resolucao_horas' as metric,
    ROUND(AVG(EXTRACT(EPOCH FROM (resolved_at - created_at))/3600), 2)::text as value,
    NOW() as timestamp
FROM ocorrencias 
WHERE resolved_at IS NOT NULL
AND created_at >= NOW() - INTERVAL '30 days';

-- =====================================================
-- COMENTÁRIOS FINAIS
-- =====================================================

COMMENT ON FUNCTION check_rate_limit IS 'Verifica e aplica rate limiting para ações do usuário';
COMMENT ON FUNCTION audit_trigger_function IS 'Função genérica para auditoria de mudanças nas tabelas';
COMMENT ON FUNCTION cleanup_old_data IS 'Remove dados antigos para manter performance do banco';
COMMENT ON VIEW backup_essential IS 'View com dados essenciais para backup (sem informações sensíveis)';
COMMENT ON VIEW monitoring_stats IS 'Métricas em tempo real para monitoramento do sistema';